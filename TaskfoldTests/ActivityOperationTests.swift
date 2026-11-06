import XCTest
@testable import TaskfoldCore

final class ActivityOperationTests: XCTestCase {
    let h = TaskNodeActivityTests()
    func nodeRow() throws -> Record {
        let before=h.root([h.node("child")]);return try XCTUnwrap(h.rows(before,h.complete(before,"child")).first)
    }
    func rootRow() throws -> Record {
        var before=Record.task(user:h.owner,project:h.project)
        before["id"] = .string(UUID().uuidString.lowercased());before["task_generation"] = .string(UUID().uuidString.lowercased())
        var after=before;after["completed"] = .bool(true);after["completed_at"] = .string("2026-10-20T09:00:00Z")
        let mutation=Mutation(table:"tasks",recordID:before.id,method:"PATCH",fields:after.fields)
        var snapshot=Snapshot();TaskActivity.recordLocal(mutation,before:before,after:after,snapshot:&snapshot,account:h.owner,now:h.now)
        return try XCTUnwrap(snapshot.tables[TaskActivity.table]?.first)
    }
    func testStrictMetadataIsDisplayOnlyAndUnknownShapesDoNotEraseWork() throws {
        let valid=ActivityOperation(id:UUID(),origin:.server_transaction)
        XCTAssertEqual(ActivityOperation(valid.document),valid)
        for value:JSON in [.null,.bool(false),.object([:]),.object(["version":.number(2),"id":.string(valid.id.uuidString),"origin":.string("server_transaction")]),.object(["version":.number(1),"id":.string("bad"),"origin":.string("server_transaction")]),.object(["version":.number(1),"id":.string(valid.id.uuidString),"origin":.string("unknown_future_origin")]),.object(valid.document.object.merging(["private_note":.string("Not grouping authority")]){_,new in new})] {
            XCTAssertNil(ActivityOperation(value))
            var row=try nodeRow();row["operation_context"]=value
            let event=try XCTUnwrap(TaskNodeActivity(row:row));XCTAssertNil(event.operation);XCTAssertEqual(event.kinds,[.completed])
            let history=ChildWorkHistory(rows:[row],epoch:[Record(["id":.string("current"),"recorded_from":.string("2026-10-01T00:00:00Z")])])
            XCTAssertEqual(ChildWorkReading(history,now:h.now).credits().count,1)
        }
    }
    func testRealProvenanceCombinesRootAndChildWithoutChangingEitherEntry() throws {
        let operation=ActivityOperation(id:UUID(),origin:.server_transaction)
        var root=try rootRow(),child=try nodeRow();root["operation_context"]=operation.document;child["operation_context"]=operation.document
        let r=try XCTUnwrap(TaskActivity(row:root)),c=try XCTUnwrap(TaskNodeActivity(row:child))
        let groups=WorkActivityGroup.reading([.root(r),.child(c)])
        XCTAssertEqual(groups.count,1);XCTAssertEqual(groups[0].events.count,2);XCTAssertEqual(groups[0].title,"Completed together")
        XCTAssertEqual(Set(groups[0].events.map(\.id)),Set(["root:"+r.id,"child:"+c.id]))
        XCTAssertEqual(groups[0].events.map(\.effectiveAt),[r.effectiveAt,c.effectiveAt])
    }
    func testEqualTimestampsNeverInferARelationship() throws {
        let r=try XCTUnwrap(TaskActivity(row:rootRow())),c=try XCTUnwrap(TaskNodeActivity(row:nodeRow()))
        XCTAssertEqual(r.recordedAt,c.recordedAt)
        XCTAssertEqual(WorkActivityGroup.reading([.root(r),.child(c)]).count,2)
    }
    func testDistinctActorOriginAndOperationRemainSeparate() throws {
        let id=UUID(),operation=ActivityOperation(id:id,origin:.server_transaction)
        var first=try rootRow(),second=try rootRow();first["operation_context"]=operation.document
        for fields:[String:JSON] in [
            ["operation_context":ActivityOperation(id:UUID(),origin:.server_transaction).document],
            ["operation_context":ActivityOperation(id:id,origin:.local_commit).document],
            ["operation_context":operation.document,"actor_id":.string(UUID().uuidString.lowercased())],
            ["operation_context":operation.document,"actor_id":.null]
        ] {
            for(k,v) in fields {second[k]=v}
            XCTAssertEqual(WorkActivityGroup.reading([.root(try XCTUnwrap(TaskActivity(row:first))),.root(try XCTUnwrap(TaskActivity(row:second)))]).count,2)
        }
    }
    func testDifferentRecordedTimesRetainOneTransactionButKeepChosenTimes() throws {
        let operation=ActivityOperation(id:UUID(),origin:.server_transaction)
        var one=try rootRow(),two=try rootRow();one["operation_context"]=operation.document;two["operation_context"]=operation.document
        two["recorded_at"] = .string(TaskActivity.stamp(h.now.addingTimeInterval(60)))
        let events=[WorkActivity.root(try XCTUnwrap(TaskActivity(row:one))),.root(try XCTUnwrap(TaskActivity(row:two)))]
        let group=try XCTUnwrap(WorkActivityGroup.reading(events).first)
        XCTAssertEqual(group.events.count,2);XCTAssertEqual(group.events.first?.recordedAt,h.now.addingTimeInterval(60));XCTAssertEqual(group.events.first?.effectiveAt,h.now.addingTimeInterval(-6*86400-3600))
        XCTAssertEqual(group.id,WorkActivityGroup.reading(Array(events.reversed()))[0].id)
    }
    func testProjectAndActorFilteringPrecedesGroupingWithoutInventingMissingMembers() throws {
        let operation=ActivityOperation(id:UUID(),origin:.server_transaction)
        var one=try rootRow(),two=try rootRow();one["operation_context"]=operation.document;two["operation_context"]=operation.document
        var before=two["before_state"].object,after=two["after_state"].object
        before["project_id"] = .string(UUID().uuidString.lowercased());after["project_id"]=before["project_id"];two["before_state"] = .object(before);two["after_state"] = .object(after)
        let events=[WorkActivity.root(try XCTUnwrap(TaskActivity(row:one))),.root(try XCTUnwrap(TaskActivity(row:two)))]
        let visible=events.filter{$0.involves(project:h.project)}
        XCTAssertEqual(visible.count,1);XCTAssertEqual(WorkActivityGroup.reading(visible)[0].events.count,1)
    }
    func testLocalCommitTouchesOnlyNewOwnedRowsAndExactRetryIsStable() throws {
        let old=try rootRow(),new=try rootRow();var foreign=try rootRow();foreign["user_id"] = .string(UUID().uuidString.lowercased())
        var snapshot=Snapshot(tables:[TaskActivity.table:[old,new,foreign]])
        let id=UUID(),counts=[TaskActivity.table:1,TaskNodeActivity.table:0]
        XCTAssertTrue(ActivityOperation.attachLocal(id:id,account:h.owner,after:counts,to:&snapshot))
        XCTAssertEqual(snapshot.tables[TaskActivity.table]![0],old);XCTAssertEqual(snapshot.tables[TaskActivity.table]![2],foreign)
        XCTAssertEqual(TaskActivity(row:snapshot.tables[TaskActivity.table]![1])?.operation,ActivityOperation(id:id,origin:.local_commit))
        let saved=snapshot;XCTAssertFalse(ActivityOperation.attachLocal(id:id,account:h.owner,after:counts,to:&snapshot));XCTAssertEqual(snapshot,saved)
    }
    func testPreparedWorkflowKeepsGroupingAndPreencodedFastPath() throws {
        let account="local",source=UUID(),run=UUID()
        let changes=(0..<2).map { i -> Mutation in
            var row=Record.task(user:account);row["title"] = .string("Workflow "+String(i))
            var change=Mutation(table:"tasks",recordID:row.id,method:"POST",fields:row.fields);change.workflowRun=run;change.insertOnly=true;return change
        }
        let initial=Snapshot(),plan=try XCTUnwrap(LocalActivityCreation.Preparation(changes:changes,snapshot:initial,source:source,account:account,labels:[],cache:nil,groupedHistory:true))
        let admission=try XCTUnwrap(plan.admit(changes,source:source,account:account,cache:nil))
        XCTAssertTrue(admission.canAdoptProjectedCreation)
        var snapshot=initial;XCTAssertTrue(admission.apply(to:&snapshot,source:source,account:account,retainingValidatedCommands:true))
        let rows=try XCTUnwrap(snapshot.tables[TaskActivity.table]);XCTAssertEqual(rows.count,2)
        XCTAssertTrue(rows.allSatisfy{TaskActivity(row:$0)?.operation==ActivityOperation(id:changes[0].id,origin:.local_commit)})
        XCTAssertFalse(ActivityOperation.attachLocal(id:changes[0].id,account:account,after:ActivityOperation.counts(initial),to:&snapshot))
        XCTAssertNotNil(try admission.encodedCache?.matching(snapshot))
    }

    func testActualServerRootChildGroupsAndUndoUseTheSharedReader() throws {
        struct Fixture: Decodable { let roots: [Record]; let children: [Record] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"activity-operation-groups",withExtension:"json",subdirectory:"Fixtures"))
        let fixture=try TaskfoldJSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        let roots=fixture.roots.compactMap { TaskActivity(row: $0) },children=fixture.children.compactMap(TaskNodeActivity.init)
        XCTAssertEqual(roots.count,10);XCTAssertEqual(children.count,8)
        let source=roots.map(WorkActivity.root)+children.map(WorkActivity.child),groups=WorkActivityGroup.reading(source)
        XCTAssertEqual(groups.count,12)
        let related=groups.filter{$0.events.count>1}
        XCTAssertEqual(related.count,6);XCTAssertTrue(related.allSatisfy{$0.events.count==2})
        XCTAssertEqual(related.filter{$0.title=="Completed together"}.count,4)
        XCTAssertEqual(related.filter{$0.title=="Reopened together"}.count,2)
        XCTAssertEqual(groups.reduce(0){$0+$1.events.count},18)
        XCTAssertTrue(related.allSatisfy{$0.events.allSatisfy{$0.operation?.origin == .server_transaction}})
        XCTAssertTrue(related.filter{$0.title=="Completed together"}.allSatisfy{Set($0.events.map(\.effectiveAt)).count==2},"Grouping must preserve the chosen parent and actual child event instants")
    }
}
