import XCTest
@testable import TaskfoldCore

final class TaskNodeActivityTests: XCTestCase {
    let owner="11111111-1111-4111-8111-111111111111",rootID="22222222-2222-4222-8222-222222222222",generation="33333333-3333-4333-8333-333333333333",project="44444444-4444-4444-8444-444444444444"
    let now=TaskPlanning.instant("2026-10-26T10:00:00Z")!
    func node(_ key:String,heading:Bool=false,done:Bool=false,children:[Record]=[]) -> Record {
        Record(["id":.string(key),"title":.string(key),"is_heading":.bool(heading),"completed":.bool(done),"subtasks":.array(children.map{.object($0.fields)})])
    }
    func root(_ children:[Record],heading:Bool=true) -> Record {
        var value=node(rootID,heading:heading,children:children);value["user_id"] = .string(owner);value["task_generation"] = .string(generation);value["project_id"] = .string(project);return value
    }
    func change(_ before:Record?,_ after:Record?,id:UUID=UUID()) -> Mutation { Mutation(id:id,table:"tasks",recordID:rootID,method:before==nil ? "POST":after==nil ? "DELETE":"PATCH",fields:after?.fields ?? [:]) }
    func rows(_ before:Record?,_ after:Record?,id:UUID=UUID(),sequence:Int64=0) -> [Record] {TaskNodeActivity.localRows(change(before,after,id:id),before:before,after:after,account:owner,recordedAt:now,afterSequence:sequence)}
    func events(_ before:Record?,_ after:Record?) -> [TaskNodeActivity] { rows(before,after).compactMap(TaskNodeActivity.init) }
    func complete(_ original:Record,_ key:String,at:String="2026-10-20T09:00:00Z") -> Record {var result=original;result["subtasks"] = SubtaskTree.changing(result["subtasks"],id:key,fields:["completed":.bool(true),"completed_at":.string(at)]);return result}
    func testIndependentChildCompletionRetainsChosenTimeWithoutCreditingHeading() throws {
        let before=root([node("first"),node("sibling")]),after=complete(before,"first"),event=try XCTUnwrap(events(before,after).first)
        XCTAssertEqual(event.kinds,[.completed]);XCTAssertEqual(event.nodeKey,"first");XCTAssertTrue(event.workBefore && event.workAfter);XCTAssertEqual(event.rootID,rootID);XCTAssertEqual(event.generation,generation)
        XCTAssertEqual(event.effectiveAt,TaskPlanning.instant("2026-10-20T09:00:00Z"));XCTAssertEqual(event.recordedAt,now);XCTAssertFalse(after.completed)
        XCTAssertEqual(event.before["project_id"],.string(project));XCTAssertFalse(event.before.keys.contains("title"))
    }
    func testOrdinaryChecklistRecordsActivityWithoutIndependentWorkCredit() throws {
        let before=root([node("checklist")],heading:false),event=try XCTUnwrap(events(before,complete(before,"checklist")).first)
        XCTAssertEqual(event.kinds,[.completed]);XCTAssertFalse(event.workBefore || event.workAfter)
    }
    func testCreationIncludesHeadingContextButNeverInventsPastCompletion() {
        let after=root([node("phase",heading:true,children:[node("done",done:true)])]),values=events(nil,after)
        XCTAssertEqual(values.count,2);XCTAssertTrue(values.allSatisfy{$0.kinds == [.created]});XCTAssertEqual(values.first{$0.nodeKey=="phase"}?.workAfter,false);XCTAssertEqual(values.first{$0.nodeKey=="done"}?.workAfter,true)
    }
    func testNotesTitlesPriorityAndUnknownOpaqueFieldsDoNotInventTransitions() {
        let before=root([node("first")]);var after=before
        after["subtasks"] = SubtaskTree.changing(after["subtasks"],id:"first",fields:["title":.string("Private renamed title"),"description":.string("Private notes"),"priority":.number(1),"opaque_future":.object(["secret":.string("do not archive")])])
        XCTAssertTrue(rows(before,after).isEmpty)
    }
    func testTwoSiblingChangesHaveDistinctStableRetryIdentities() {
        let before=root([node("a"),node("b")]),after=complete(complete(before,"a"),"b"),id=UUID()
        let first=rows(before,after,id:id),retry=rows(before,after,id:id,sequence:50)
        XCTAssertEqual(first.count,2);XCTAssertEqual(Set(first.map(\.id)).count,2);XCTAssertEqual(first.map(\.id),retry.map(\.id));XCTAssertEqual(first.map{$0["sequence"].integer},[1,2]);XCTAssertEqual(retry.map{$0["sequence"].integer},[51,52])
    }
    func testLocalRecorderIsAtomicRetrySafeAndDoesNotRewriteParentLedgerOrTasks() {
        let before=root([node("first")]),after=complete(before,"first"),mutation=change(before,after)
        var snapshot=Snapshot(tables:["tasks":[after],TaskActivity.table:[]]);let original=snapshot.tables["tasks"]
        TaskNodeActivity.recordLocal(mutation,before:before,after:after,snapshot:&snapshot,account:owner,now:now)
        let saved=snapshot;TaskNodeActivity.recordLocal(mutation,before:before,after:after,snapshot:&snapshot,account:owner,now:now.addingTimeInterval(1))
        XCTAssertEqual(snapshot,saved);XCTAssertEqual(snapshot.tables["tasks"],original);XCTAssertTrue(snapshot.tables[TaskActivity.table]?.isEmpty==true);XCTAssertEqual(snapshot.tables[TaskNodeActivity.epochTable]?.count,1);XCTAssertTrue(snapshot.pending.isEmpty)
    }
    func testUndoAndRedoAreObservedRealTransitions() throws {
        let before=root([node("first")]),done=complete(before,"first")
        XCTAssertEqual(events(before,done).first?.kinds,[.completed]);XCTAssertEqual(events(done,before).first?.kinds,[.reopened]);XCTAssertEqual(events(before,done).first?.kinds,[.completed])
    }
    func testGroupingChangeDoesNotInventCompletionForAlreadyCompletedChild() throws {
        let before=root([node("done",done:true)]);var after=before;after["is_heading"] = .bool(false)
        let value=try XCTUnwrap(events(before,after).first);XCTAssertEqual(value.kinds,[.scope_changed]);XCTAssertTrue(value.workBefore);XCTAssertFalse(value.workAfter)
        XCTAssertEqual(events(after,before).first?.kinds,[.scope_changed])
    }
    func testTaskHeadingConversionRetainsIdentityAndPromotesDescendantsWithoutCreation() {
        let before=root([node("container",children:[node("child")])]);var after=before
        after["subtasks"] = SubtaskTree.changing(after["subtasks"],id:"container",fields:["is_heading":.bool(true)])
        let values=events(before,after);XCTAssertEqual(values.count,2)
        XCTAssertEqual(values.first{$0.nodeKey=="container"}?.kinds,[.type_changed]);XCTAssertEqual(values.first{$0.nodeKey=="child"}?.kinds,[.scope_changed]);XCTAssertTrue(values.allSatisfy{!$0.kinds.contains(.created) && !$0.kinds.contains(.completed)})
    }
    func testMovingAChildUsesStableSubjectAndFreshCurrentPath() throws {
        let before=root([node("child"),node("phase",heading:true)]),after=root([node("phase",heading:true,children:[node("child")])])
        let event=try XCTUnwrap(events(before,after).first{$0.nodeKey=="child"})
        XCTAssertEqual(event.kinds,[.moved]);XCTAssertEqual(event.beforePath,["child"]);XCTAssertEqual(event.afterPath,["phase","child"])
        let previous=try XCTUnwrap(events(nil,before).first{$0.nodeKey=="child"});XCTAssertEqual(event.subject,previous.subject)
        let current=try XCTUnwrap(event.currentTask(tasks:[after],projects:[Record(["id":.string(project),"name":.string("Studio")])],account:owner))
        XCTAssertEqual(SubtaskTree.referencePath(current.id),[rootID,"phase","child"])
    }
    func testRootProjectMoveIsInheritedButNodeEmbeddedDestinationsAreIgnored() throws {
        var child=node("child");child["project_id"] = .string("private-spoof");let before=root([child]);var after=before;after["project_id"] = .string("55555555-5555-4555-8555-555555555555")
        let event=try XCTUnwrap(events(before,after).first);XCTAssertEqual(event.kinds,[.moved]);XCTAssertEqual(event.before["project_id"],.string(project));XCTAssertEqual(event.after["project_id"],after["project_id"])
    }
    func testRecreatedRootIsAnotherOccurrenceAndOldHistoryCannotOpenIt() throws {
        let before=root([node("child")]);var after=before;after["task_generation"] = .string(UUID().uuidString.lowercased())
        let values=events(before,after);XCTAssertEqual(Set(values.map{ $0.kinds.first! }),[.created,.deleted]);XCTAssertEqual(Set(values.map(\.subject)).count,2)
        let prior=try XCTUnwrap(events(nil,before).first);XCTAssertNil(prior.currentTask(tasks:[after],projects:[Record(["id":.string(project)])],account:owner))
    }
    func testMalformedAndLegacyTreesRecordExplicitGapWithoutInventingOrRepairingNodes() {
        let before=root([node("child")]);var bad=before;bad["subtasks"] = .array([.object(node("duplicate").fields),.object(node("duplicate").fields)])
        let original=bad;let values=events(before,bad);XCTAssertEqual(values.count,1);XCTAssertTrue(values[0].isGap);XCTAssertFalse(values[0].workAfter);XCTAssertEqual(bad,original)
        bad["subtasks"] = .array([.string("Legacy private title")]);XCTAssertTrue(events(before,bad).first?.isGap==true)
    }
    func testInvalidTypeBooleanCounterAndDateProduceGap() {
        let before=root([node("child")])
        for fields: [String:JSON] in [["is_heading":.string("future")],["completed":.string("yes")],["completion_version":.number(-1)],["due_date":.string("not-a-day")]] {
            var after=before;after["subtasks"] = SubtaskTree.changing(after["subtasks"],id:"child",fields:fields)
            XCTAssertTrue(events(before,after).first?.isGap==true,fields.description)
        }
    }
    func testEquivalentTimestampSpellingsDoNotInventCompletionTimeEvent() {
        var child=node("child",done:true);child["completed_at"] = .string("2026-10-20T09:00:00Z");let before=root([child]);var after=before
        after["subtasks"] = SubtaskTree.changing(after["subtasks"],id:"child",fields:["completed_at":.string("2026-10-20T11:00:00+02:00")])
        XCTAssertTrue(events(before,after).isEmpty)
    }
    func testUnsupportedEnvelopePathsAndWorkFlagsFailClosed() throws {
        let before=root([node("child")]);let valid=try XCTUnwrap(rows(before,complete(before,"child")).first)
        for fields:[String:JSON] in [["format_version":.number(2)],["after_path":.array([.string("other")])],["type_after":.string("future")],["type_after":.string("heading"),"work_after":.bool(true)],["sequence":.number(0)],["task_generation":.string("bad")]] {
            var damaged=valid;for (k,v) in fields{damaged[k]=v};XCTAssertNil(TaskNodeActivity(row:damaged),fields.description)
        }
    }
    func testPrivateOwnerAndIncarnationAreRequiredForHistoryRoute() throws {
        var before=root([node("child")]);before["project_id"] = .null;let event=try XCTUnwrap(events(before,complete(before,"child")).first)
        XCTAssertNotNil(event.currentTask(tasks:[before],projects:[],account:owner));XCTAssertNil(event.currentTask(tasks:[before],projects:[],account:"other"))
        var changed=before;changed["user_id"] = .string("other");XCTAssertNil(event.currentTask(tasks:[changed],projects:[],account:owner))
        XCTAssertNil(event.currentTask(tasks:[before,before],projects:[],account:owner))
    }
    func testSequenceExhaustionNeverWritesHalfAMultiNodeTransition() {
        let before=root([node("a"),node("b")]),after=complete(complete(before,"a"),"b")
        XCTAssertTrue(rows(before,after,sequence:9_007_199_254_740_990).isEmpty)
    }
    func testFutureExistingLedgerIsPreservedWithoutResettingItsCursor() {
        let before=root([node("child")]),after=complete(before,"child");var snapshot=Snapshot(tables:[TaskNodeActivity.table:[Record(["id":.string(UUID().uuidString),"format_version":.number(2),"sequence":.number(100)])]])
        let original=snapshot;TaskNodeActivity.recordLocal(change(before,after),before:before,after:after,snapshot:&snapshot,account:owner,now:now);XCTAssertEqual(snapshot,original)
    }
    func testWrongAccountAndRootCannotManufactureLocalHistory() {
        let before=root([node("child")]),after=complete(before,"child")
        XCTAssertTrue(TaskNodeActivity.localRows(change(before,after),before:before,after:after,account:"other",recordedAt:now).isEmpty)
        var foreign=before;foreign["user_id"] = .string("other");XCTAssertTrue(rows(foreign,after).isEmpty)
        let unrelated=Mutation(table:"tasks",recordID:"other",method:"PATCH",fields:[:]);XCTAssertTrue(TaskNodeActivity.localRows(unrelated,before:before,after:after,account:owner,recordedAt:now).isEmpty)
    }
    func testActualPostgresRowsDecodeWithSameWorkAndIdentityContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-node-activity", withExtension: "json", subdirectory: "Fixtures"))
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(records.count, 30)
        let events = try records.map { try XCTUnwrap(TaskNodeActivity(row: $0), $0.id) }
        XCTAssertTrue(events.contains { $0.isGap })
        XCTAssertTrue(events.contains { $0.kinds == [.completed] && $0.workAfter })
        XCTAssertTrue(events.contains { $0.kinds == [.completed] && !$0.workAfter })
        XCTAssertEqual(Set(events.map(\.sequence)).count, events.count)
    }
    func testLegacyGenerationCanBeReadButCannotRouteIntoCurrentData() throws {
        var value = root([node("child")]); value["task_generation"] = .null
        let event = try XCTUnwrap(events(nil, value).first)
        XCTAssertEqual(event.generation, TaskNodeActivity.legacyGeneration)
        XCTAssertNil(event.currentTask(tasks: [value], projects: [Record(["id": .string(project)])], account: owner))
    }

    func testBackupPreservesChildArchiveWithoutReplayingOrRemappingHistory() throws {
        let task = root([node("child")]), done = complete(task, "child")
        let archive = rows(task, done)
        let epoch = Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])
        let snapshot = Snapshot(tables: ["tasks": [done], "projects": [Record(["id": .string(project), "name": .string("Studio"), "user_id": .string(owner)])], TaskNodeActivity.table: archive, TaskNodeActivity.epochTable: [epoch]])
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        XCTAssertEqual(backup.tables[TaskNodeActivity.table], archive)
        XCTAssertEqual(backup.tables[TaskNodeActivity.epochTable], [epoch])
        let plan = try backup.plan(current: Snapshot(), account: "55555555-5555-4555-8555-555555555555")
        XCTAssertFalse(plan.changes.contains { [TaskNodeActivity.table, TaskNodeActivity.epochTable].contains($0.table) })
        XCTAssertTrue(plan.warnings.contains { $0.contains("archive") && $0.contains("not replayed") })
        XCTAssertNotEqual(plan.changes.first { $0.table == "tasks" }?.fields["task_generation"], .string(generation))
    }
    func testBackupRejectsFutureDuplicateOrInvalidChildHistoryWithoutChangingSource() throws {
        let task = root([node("child")]), valid = try XCTUnwrap(rows(task, complete(task, "child")).first)
        for edit: [String: JSON] in [["format_version": .number(2)], ["after_path": .array([.string("other")])], ["sequence": .number(0)]] {
            var damaged = valid; for (key, value) in edit { damaged[key] = value }
            let snapshot = Snapshot(tables: [TaskNodeActivity.table: [damaged]])
            let original = snapshot
            XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data()))
            XCTAssertEqual(snapshot, original)
        }
        var sameSequence = valid; sameSequence["id"] = .string(UUID().uuidString)
        for values in [[valid, valid], [valid, sameSequence]] {
            XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: [TaskNodeActivity.table: values]), account: owner).data()))
        }
        for values in [[], [Record(["id": .string("other"), "recorded_from": .string(TaskActivity.stamp(now))])], [Record(["id": .string("current"), "recorded_from": .string("invalid")])]] where !values.isEmpty {
            XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: [TaskNodeActivity.epochTable: values]), account: owner).data()))
        }
    }
    func testFreshTasksDiscardUnavailableArchiveButKeepQueueAndOtherHistory() {
        let task = root([node("child")]), archive = rows(task, complete(task, "child"))
        let epoch = Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])
        let queued = change(task, complete(task, "child"))
        let original = Snapshot(tables: ["tasks": [task], TaskNodeActivity.table: archive, TaskNodeActivity.epochTable: [epoch], TaskActivity.table: []], pending: [queued])
        for remote: [String: [Record]] in [["tasks": [task]], ["tasks": [task], TaskNodeActivity.table: archive], ["tasks": [task], TaskNodeActivity.epochTable: [epoch]]] {
            var next = original; next.mergeRemote(remote)
            XCTAssertNil(next.tables[TaskNodeActivity.table]); XCTAssertNil(next.tables[TaskNodeActivity.epochTable]); XCTAssertEqual(next.pending, [queued]); XCTAssertEqual(next.tables[TaskActivity.table], [])
        }
        var offline = original; offline.mergeRemote(["labels": []]); XCTAssertEqual(offline.tables[TaskNodeActivity.table], archive)
        var refreshed = original; refreshed.mergeRemote(["tasks": [task], TaskNodeActivity.table: [], TaskNodeActivity.epochTable: [epoch]])
        XCTAssertEqual(refreshed.tables[TaskNodeActivity.table], []); XCTAssertEqual(refreshed.tables[TaskNodeActivity.epochTable], [epoch])
    }
    @MainActor func historyBackend() throws -> (Backend, Session) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"test\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + owner + "\"}}").utf8))
        return (Backend(configuration: ["URL": "https://native-auth.test", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in }), session)
    }
    @MainActor func testOptionalNetworkHistoryRequiresCompleteStableEpochAndPreservesEmpty() async throws {
        let (backend, _) = try historyBackend()
        let epoch = try JSONEncoder().encode([Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])])
        defer { AuthTransportTests.Stub.handler = nil }
        var calls = 0
        AuthTransportTests.Stub.handler = { request in
            calls += 1
            return (200, request.url!.path.hasSuffix("epoch") ? epoch : Data("[]".utf8))
        }
        let empty = await backend.nodeActivityHistory()
        XCTAssertEqual(empty?.rows, []); XCTAssertEqual(calls, 3)
        for status in [403, 404, 500] {
            for failedPath in [TaskNodeActivity.epochTable, TaskNodeActivity.table] {
                AuthTransportTests.Stub.handler = { request in
                    if request.url!.lastPathComponent == failedPath { return (status, Data("{\"message\":\"Unavailable\"}".utf8)) }
                    return (200, epoch)
                }
                let unavailable = await backend.nodeActivityHistory(); XCTAssertNil(unavailable)
            }
        }
        AuthTransportTests.Stub.handler = { _ in (200, Data("[]".utf8)) }
        let missingEpoch = await backend.nodeActivityHistory(); XCTAssertNil(missingEpoch)
        var epochs = 0
        AuthTransportTests.Stub.handler = { request in
            if request.url!.path.hasSuffix("epoch") {
                epochs += 1
                return (200, epochs == 1 ? epoch : Data("[{\"id\":\"current\",\"recorded_from\":\"2026-10-27T10:00:00Z\"}]".utf8))
            }
            return (200, Data("[]".utf8))
        }
        let reset = await backend.nodeActivityHistory(); XCTAssertNil(reset)
    }
    @MainActor func testNetworkHistoryPagesBySequenceAndRejectsPartialFutureDuplicateOrUnorderedFeed() async throws {
        let (backend, _) = try historyBackend(), task = root([node("child")])
        let template = try XCTUnwrap(rows(task, complete(task, "child")).first)
        let epoch = try JSONEncoder().encode([Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])])
        var first = (1...500).map { sequence in var row = template; row["sequence"] = .number(Double(sequence)); row["id"] = .string(UUID().uuidString); return row }
        var last = template; last["sequence"] = .number(503); last["id"] = .string(UUID().uuidString)
        defer { AuthTransportTests.Stub.handler = nil }
        var pages = 0
        AuthTransportTests.Stub.handler = { request in
            if request.url!.path.hasSuffix("epoch") { return (200, epoch) }
            pages += 1
            XCTAssertTrue(request.url!.query!.contains(pages == 1 ? "sequence=gt.0" : "sequence=gt.500"))
            XCTAssertFalse(request.url!.query!.contains("offset="))
            return (200, try JSONEncoder().encode(pages == 1 ? first : [last]))
        }
        let full = await backend.nodeActivityHistory(); XCTAssertEqual(full?.rows.count, 501); XCTAssertEqual(pages, 2)
        for problem in ["later failure", "duplicate ID", "unordered", "future", "oversized"] {
            pages = 0
            AuthTransportTests.Stub.handler = { request in
                if request.url!.path.hasSuffix("epoch") { return (200, epoch) }
                pages += 1
                if pages == 1 {
                    if problem == "oversized" { return (200, try JSONEncoder().encode(first + [last])) }
                    return (200, try JSONEncoder().encode(first))
                }
                if problem == "later failure" { return (500, Data("{}".utf8)) }
                var bad = last
                if problem == "duplicate ID" { bad["id"] = first[0]["id"] }
                if problem == "unordered" { bad["sequence"] = .number(500) }
                if problem == "future" { bad["format_version"] = .number(2) }
                return (200, try JSONEncoder().encode([bad]))
            }
            let incomplete = await backend.nodeActivityHistory(); XCTAssertNil(incomplete, problem)
        }
        first[0]["sequence"] = .number(0)
        AuthTransportTests.Stub.handler = { request in (200, request.url!.path.hasSuffix("epoch") ? epoch : try JSONEncoder().encode(first)) }
        let invalid = await backend.nodeActivityHistory(); XCTAssertNil(invalid)
    }
    @MainActor func testNetworkHistoryDiscardsSameAccountSessionCycle() async throws {
        let (backend, session) = try historyBackend()
        let epoch = try JSONEncoder().encode([Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(now))])])
        let started = expectation(description: "Child history read started"), gate = DispatchSemaphore(value: 0)
        defer { AuthTransportTests.Stub.handler = nil; gate.signal() }
        AuthTransportTests.Stub.handler = { request in
            if request.url!.path.hasSuffix("epoch") { return (200, epoch) }
            started.fulfill(); _ = gate.wait(timeout: .now() + 10)
            return (200, Data("[]".utf8))
        }
        let read = Task { await backend.nodeActivityHistory(expectedAccount: owner) }
        await fulfillment(of: [started], timeout: 5)
        var other = session; other.user.id = "55555555-5555-4555-8555-555555555555"
        try await backend.accept(other); try await backend.accept(session); gate.signal()
        let stale = await read.value; XCTAssertNil(stale)
    }
    @MainActor func testChildHistoryAndEpochRejectAllClientWritesBeforeNetwork() async throws {
        let (backend, _) = try historyBackend()
        AuthTransportTests.Stub.handler = { _ in XCTFail("Read-only history sent a request"); return (200, Data("[]".utf8)) }
        defer { AuthTransportTests.Stub.handler = nil }
        for table in [TaskNodeActivity.table, TaskNodeActivity.epochTable] {
            for method in ["POST", "PATCH", "DELETE"] {
                do { _ = try await backend.send(Mutation(table: table, recordID: UUID().uuidString, method: method, fields: [:])); XCTFail("History write accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("read-only")) }
            }
        }
    }

    func testActualEditHistoryRedoIsNewActionWhileTransportRetryStaysIdempotent() throws {
        let before = root([node("child")]), after = complete(before, "child"), original = change(before, after)
        let history = EditHistory(changes: [original], snapshot: Snapshot(tables: ["tasks": [before]]))
        var snapshot = Snapshot(tables: ["tasks": [before]])
        func commit(_ mutation: Mutation) {
            let prior = snapshot.tables["tasks"]?.first; snapshot.apply(mutation)
            TaskNodeActivity.recordLocal(mutation, before: prior, after: snapshot.tables["tasks"]?.first, snapshot: &snapshot, account: owner, now: now)
        }
        commit(original)
        let undo = TeamCompletion.historyAction(try XCTUnwrap(history.undo.first), snapshot: snapshot)
        commit(undo)
        let open = try XCTUnwrap(snapshot.tables["tasks"]?.first)
        let redo = TeamCompletion.historyAction(try XCTUnwrap(history.redo.first), snapshot: snapshot)
        XCTAssertNotEqual(redo.id, original.id); XCTAssertNotEqual(redo.id, undo.id)
        commit(redo)
        let rows = snapshot.tables[TaskNodeActivity.table] ?? []
        XCTAssertEqual(rows.compactMap(TaskNodeActivity.init).map(\.kinds), [[.completed], [.reopened], [.completed]])
        TaskNodeActivity.recordLocal(redo, before: open, after: snapshot.tables["tasks"]?.first, snapshot: &snapshot, account: owner, now: now.addingTimeInterval(2))
        XCTAssertEqual(snapshot.tables[TaskNodeActivity.table], rows)
    }

    func testLocalAppendValidatesFiveThousandExistingEventsWithoutLosingCoverage() throws {
        let before = root([node("child")]), after = complete(before, "child"), template = try XCTUnwrap(rows(before, after).first)
        let events = (1...5000).map { index -> Record in
            var row = template
            row["sequence"] = .number(Double(index)); row["id"] = .string(WorkspaceBackup.stableID("child-history-performance", String(index)))
            row["task_id"] = .string(WorkspaceBackup.stableID("child-history-existing-root", String(index)))
            let stamp = TaskActivity.stamp(now.addingTimeInterval(-Double(index)))
            row["recorded_at"] = .string(stamp); row["effective_at"] = .string(stamp)
            var state = row["after_state"].object; state["completed_at"] = .string(stamp); row["after_state"] = .object(state)
            return row
        }
        var snapshot = Snapshot(tables: [TaskNodeActivity.table: events])
        let start = Date()
        TaskNodeActivity.recordLocal(change(after, before), before: after, after: before, snapshot: &snapshot, account: owner, now: now)
        print("CHILD_HISTORY_APPEND_5000_SECONDS=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(snapshot.tables[TaskNodeActivity.table]?.count, 5001)
        XCTAssertEqual(snapshot.tables[TaskNodeActivity.table]?.last?["sequence"], .number(5001))
    }

    func testCachedParserRetainsExactValidationAndTimestampSemantics() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-node-activity", withExtension: "json", subdirectory: "Fixtures"))
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        let parser = TaskNodeActivity.Parser()
        for row in records { XCTAssertEqual(parser.event(row), TaskNodeActivity(row: row)) }
        let valid = try XCTUnwrap(rows(nil, root([node("child")])).first)
        for stamp in ["2026-10-20T09:00:00Z", "2026-10-20T11:00:00.123456+02:00", "not-an-instant", ""] {
            var row = valid; row["recorded_at"] = .string(stamp); row["effective_at"] = .string(stamp)
            XCTAssertEqual(parser.event(row), TaskNodeActivity(row: row))
        }
        for day in ["2026-10-26", "2026-02-30", "invalid"] {
            var row = valid; var state = row["after_state"].object; state["due_date"] = .string(day); row["after_state"] = .object(state)
            XCTAssertEqual(parser.event(row), TaskNodeActivity(row: row))
        }
        var future = valid; future["format_version"] = .number(2); XCTAssertNil(parser.event(future))
    }

    func testRetainedTeamSQLHistoryDecodesAndArchivesWithoutActorOrOwnerRewriting() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-node-custody", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        let events = try rows.map { try XCTUnwrap(TaskNodeActivity(row: $0), $0.id) }
        XCTAssertTrue(events.contains { $0.actor == nil }); XCTAssertTrue(events.contains { $0.actor != nil && $0.actor != $0.owner })
        let account = try XCTUnwrap(events.compactMap(\.actor).first)
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: [TaskNodeActivity.table: rows]), account: account).data())
        XCTAssertEqual(file.tables[TaskNodeActivity.table], rows)
        XCTAssertTrue(try file.plan(current: Snapshot(), account: UUID().uuidString.lowercased()).changes.isEmpty)
    }
    func testRetainedAuthorHistoryRoutesForCurrentMemberOnlyThroughFreshProjectCatalog() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-node-custody", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        let event = try XCTUnwrap(rows.compactMap(TaskNodeActivity.init).first { $0.actor != nil && $0.actor != $0.owner && $0.kinds == [.completed] && $0.workAfter })
        let member = try XCTUnwrap(event.actor), project = try XCTUnwrap(event.after["project_id"]?.text)
        var root = Record.task(user: event.owner, project: project); root["id"] = .string(event.rootID); root["task_generation"] = .string(try XCTUnwrap(event.generation)); root["is_heading"] = .bool(true)
        root["subtasks"] = .array([.object(["id": .string(event.nodeKey), "title": .string("Current retained child"), "completed": .bool(true)])])
        let current = event.currentTask(tasks: [root], projects: [Record(["id": .string(project), "name": .string("Shared studio")])], account: member)
        XCTAssertEqual(current?.title, "Current retained child"); XCTAssertNil(event.currentTask(tasks: [root], projects: [], account: member))
    }

}
