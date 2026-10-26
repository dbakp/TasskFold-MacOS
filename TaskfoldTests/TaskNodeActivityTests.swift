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

}
