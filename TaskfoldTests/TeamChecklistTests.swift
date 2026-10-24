import XCTest
@testable import TaskfoldCore

final class TeamChecklistTests: XCTestCase {
    private let scope = TeamTaskEditScope(account:"10000000-0000-4000-8000-000000000001",origin:"https://backend.example",team:"10000000-0000-4000-8000-000000000002",project:"10000000-0000-4000-8000-000000000003")
    private let generation = "10000000-0000-4000-8000-000000000004"
    private let task = "10000000-0000-4000-8000-000000000005"
    private func child(_ id:String="child", completed:Bool=false, version:Double?=nil)->JSON {
        var row:[String:JSON] = ["id":.string(id),"title":.string(id),"completed":.bool(completed),"subtasks":.array([])]
        if let version {row[TeamChecklist.key] = .object(["epoch":.string(generation),"version":.number(version)])}
        return .object(row)
    }
    private func mutation(_ desired:[JSON],base:[JSON]=[]) -> Mutation {
        Mutation(table:"tasks",recordID:task,method:"PATCH",fields:["subtasks":.array(desired)],baseline:["project_id":.string(scope.project),"task_generation":.string(generation),"subtasks":.array(base)],teamTaskScope:scope)
    }
    private func fixture() throws -> (Mutation, TeamTaskEditScope, [String:JSON], Record) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-checklist-v1",withExtension:"json",subdirectory:"Fixtures"))
        let raw=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))["checklist"]!.object
        let body=raw["body"]!.object
        let context=TeamTaskEditScope(account:raw["account"]!.text,origin:"https://backend.example",team:body["team_id"]!.text,project:body["project_id"]!.text)
        return(Mutation(id:try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),table:"tasks",recordID:body["task_id"]!.text,method:"PATCH",fields:body["changes"]!.object,baseline:body["base"]!.object,teamTaskScope:context),context,raw["reply"]!.object,Record(raw["before"]!.object))
    }
    func testNewItemGetsStablePersistedEpochBeforeTransport() throws {
        let first=try TeamChecklist.preparing(mutation([child()]))
        let nodes=try TeamChecklist.indexed(first.fields["subtasks"]!)
        let token=try XCTUnwrap(TeamChecklist.token(nodes["child"]?[TeamChecklist.key]))
        XCTAssertEqual(token.version,0);XCTAssertTrue(TeamProjectValue.id(token.epoch))
        XCTAssertEqual(try TeamChecklist.preparing(first),first)
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(first)),first)
        XCTAssertNoThrow(try scope.body(for:first))
    }
    func testCompletionPredictsNextRevisionWithoutChangingEpoch() throws {
        let old=child(version:3),desired=child(completed:true,version:3)
        let change=try TeamChecklist.preparing(mutation([desired],base:[old]))
        let token=try XCTUnwrap(TeamChecklist.token(try TeamChecklist.indexed(change.fields["subtasks"]!)["child"]?[TeamChecklist.key]))
        XCTAssertEqual(token.epoch,generation);XCTAssertEqual(token.version,4)
        XCTAssertEqual(try TeamChecklist.preparing(change),change)
    }
    func testLegacyItemGetsStableEpochOnFirstEdit() throws {
        let original=child(),change=try TeamChecklist.preparing(mutation([original],base:[original]))
        XCTAssertEqual(try TeamChecklist.preparing(change),change)
        let token=try XCTUnwrap(TeamChecklist.token(try TeamChecklist.indexed(change.fields["subtasks"]!)["child"]?[TeamChecklist.key]))
        XCTAssertEqual(token.version,0)
    }
    func testRestorationAlwaysHasFreshStableIncarnation() throws {
        var context=scope;context.checklistRestoreRequest=UUID()
        var change=mutation([child(version:0)]);change.teamTaskScope=context
        let first=try TeamChecklist.preparing(change),second=try TeamChecklist.preparing(first)
        XCTAssertEqual(first,second)
        let epoch=try XCTUnwrap(TeamChecklist.token(try TeamChecklist.indexed(first.fields["subtasks"]!)["child"]?[TeamChecklist.key]))
        XCTAssertNotEqual(epoch.epoch,generation)
        var next=change;next.id=UUID()
        XCTAssertNotEqual(try TeamChecklist.preparing(next).fields,first.fields)
        XCTAssertEqual(try context.body(for:first)["checklist_restore_from"],.string(context.checklistRestoreRequest!.uuidString.lowercased()))
    }
    func testPrivateHistoryAndOpaqueFieldsSurvivePreparation() throws {
        var row=child(version:0).object
        row["comments"] = .array([.object(["text":.string("Keep discussion")])]);row["attachments"] = .array([.object(["url":.string("https://example.invalid/file")])]);row["future_state"] = .object(["keep":.bool(true)])
        let change=try TeamChecklist.preparing(mutation([.object(row)],base:[.object(row)]))
        let prepared=try XCTUnwrap(try TeamChecklist.indexed(change.fields["subtasks"]!)["child"])
        for key in ["comments","attachments","future_state"] {XCTAssertEqual(prepared[key],row[key])}
    }
    func testTreeBoundsAndAmbiguousIdentitiesAreRejected() throws {
        for invalid in [JSON.null,.object([:]),.array([.string("text")]),.array([child(),child()]),.array([.object(["id":.number(1)])])] {XCTAssertThrowsError(try TeamChecklist.indexed(invalid))}
        let huge=JSON.array((0...1000).map{child(String($0))});XCTAssertThrowsError(try TeamChecklist.indexed(huge))
        var nested=JSON.array([])
        for i in 0..<25 {var row=child(String(i)).object;row["subtasks"]=nested;nested = .array([.object(row)])}
        XCTAssertThrowsError(try TeamChecklist.indexed(nested))
    }
    func testMalformedAndExhaustedCompletionTokensStayLocal() throws {
        let bad:[JSON] = [.null,.number(1),.object(["epoch":.string(generation),"version":.number(-1)]),.object(["epoch":.string(generation),"version":.number(0.5)]),.object(["epoch":.string(generation),"version":.number(.infinity)]),.object(["epoch":.string("wrong"),"version":.number(0)])]
        for value in bad {var row=child().object;row[TeamChecklist.key]=value;XCTAssertThrowsError(try TeamChecklist.validate(.array([.object(row)])))}
        let old=child(version:TeamChecklist.maximumVersion),desired=child(completed:true,version:TeamChecklist.maximumVersion)
        XCTAssertThrowsError(try TeamChecklist.preparing(mutation([desired],base:[old])))
    }
    func testPersonalMutationIsUnchanged() throws {
        var change=mutation([child()]);change.teamTaskScope=nil
        XCTAssertEqual(try TeamChecklist.preparing(change),change)
    }
    func testSQLReplyConfirmsNestedRevisionAndRetainedHistory() throws {
        let(change,context,reply,before)=try fixture()
        XCTAssertEqual(try context.body(for:change)["changes"],.object(change.fields))
        let saved=try context.saved(reply,for:change),beforeNodes=try TeamChecklist.indexed(before["subtasks"]),afterNodes=try TeamChecklist.indexed(saved["subtasks"])
        XCTAssertEqual(afterNodes["child-check"]?["completed"],.bool(false))
        XCTAssertEqual(TeamChecklist.token(afterNodes["child-check"]?[TeamChecklist.key])?.version,1)
        for key in ["comments","attachments","future_state","reminder_specs"] {XCTAssertEqual(afterNodes["child-check"]?[key],beforeNodes["child-check"]?[key])}
        XCTAssertNoThrow(try context.capturing(change,existing:before))
    }
    func testUndoCarriesExactChecklistActionReceipt() throws {
        let(change,context,_,before)=try fixture();var snapshot=Snapshot();snapshot.tables=["tasks":[before]]
        let history=EditHistory(changes:[change],snapshot:snapshot),back=try XCTUnwrap(history.undo.first),backScope=try XCTUnwrap(back.teamTaskScope)
        XCTAssertEqual(backScope.checklistRestoreRequest,change.id);XCTAssertEqual(backScope.account,context.account)
        XCTAssertEqual(try backScope.body(for:back)["checklist_restore_from"],.string(change.id.uuidString.lowercased()))
        XCTAssertEqual(history.redo.first?.teamTaskScope?.checklistRestoreRequest,nil)
        var snapshotAfter=snapshot;snapshotAfter.apply(change)
        let prepared=try backScope.capturing(back,existing:XCTUnwrap(snapshotAfter.tables["tasks"]?.first))
        XCTAssertEqual(prepared.teamTaskScope?.checklistRestoreRequest,change.id)
    }
    func testRestoreContextRequiresTreeAndOldScopesDecode() throws {
        var context=scope;context.checklistRestoreRequest=UUID();var change=mutation([])
        change.fields=["title":.string("Name")];change.baseline?["title"] = .string("Old")
        XCTAssertThrowsError(try context.body(for:change))
        var old=try JSONDecoder().decode([String:JSON].self,from:JSONEncoder().encode(scope));old.removeValue(forKey:"checklistRestoreRequest")
        XCTAssertNil(try JSONDecoder().decode(TeamTaskEditScope.self,from:JSONEncoder().encode(old)).checklistRestoreRequest)
    }
    func testNativeRestorationEpochMatchesActualSQLReceipt() throws {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-checklist-v1",withExtension:"json",subdirectory:"Fixtures"))
        let raw=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))["checklist"]!.object
        let body=raw["recovery_body"]!.object,reply=raw["recovery_reply"]!.object
        var context=TeamTaskEditScope(account:raw["account"]!.text,origin:"https://backend.example",team:body["team_id"]!.text,project:body["project_id"]!.text)
        context.checklistRestoreRequest=try XCTUnwrap(UUID(uuidString:body["checklist_restore_from"]!.text))
        let change=Mutation(id:try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),table:"tasks",recordID:body["task_id"]!.text,method:"PATCH",fields:body["changes"]!.object,baseline:body["base"]!.object,teamTaskScope:context)
        let prepared=try TeamChecklist.preparing(change)
        XCTAssertEqual(prepared.fields,change.fields)
        XCTAssertEqual(try context.body(for:prepared),body)
        let saved=try context.saved(reply,for:prepared)
        XCTAssertEqual(try TeamChecklist.indexed(saved["subtasks"])["child-check"]?[TeamChecklist.key],try TeamChecklist.indexed(change.fields["subtasks"]!)["child-check"]?[TeamChecklist.key])
    }
    func testSuccessorChildrenLeavePriorCompletionIncarnation() throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let at=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-10-24T12:00:00Z"))
        let original=Record(["id":.string(task),"user_id":.string(scope.account),"project_id":.string(scope.project),"title":.string("Repeat"),"completed":.bool(false),"task_generation":.string(generation),"completion_version":.number(0),"due_date":.string("2026-10-24"),"is_recurring":.bool(true),"recurrence_pattern":.object(["type":.string("daily"),"interval":.number(1),"count":.number(2)]),"subtasks":.array([child(completed:true,version:3)])])
        var creation=try XCTUnwrap(TaskCompletion.toggle(original,tasks:[original],at:at,calendar:calendar,account:scope.account).last)
        XCTAssertEqual(creation.method,"POST")
        let raw=try TeamChecklist.indexed(creation.fields["subtasks"]!)
        XCTAssertNil(raw.values.first?[TeamChecklist.key])
        creation.teamTaskScope=scope
        let prepared=try TeamChecklist.preparing(creation)
        let value=try XCTUnwrap(TeamChecklist.token(try TeamChecklist.indexed(prepared.fields["subtasks"]!).values.first?[TeamChecklist.key]))
        XCTAssertEqual(value.version,0);XCTAssertNotEqual(value.epoch,generation)
    }

    func testWholeTaskRestorationPreservesCertifiedChecklistExactly() throws {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-checklist-v1",withExtension:"json",subdirectory:"Fixtures"))
        let raw=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))["checklist"]!.object
        let body=raw["root_recovery_body"]!.object,reply=raw["root_recovery_reply"]!.object
        var context=TeamTaskEditScope(account:raw["account"]!.text,origin:"https://backend.example",team:body["team_id"]!.text,project:body["project_id"]!.text)
        context.restoreRequest=try XCTUnwrap(UUID(uuidString:body["restore_from"]!.text))
        let change=Mutation(id:try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),table:"tasks",recordID:body["task_id"]!.text,method:"POST",fields:body["record"]!.object,insertOnly:true,teamTaskScope:context)
        XCTAssertEqual(try TeamChecklist.preparing(change),change)
        XCTAssertEqual(try context.capturing(change,existing:nil),change)
        XCTAssertEqual(try context.lifecycleBody(for:change),body)
        let restored=try XCTUnwrap(context.lifecycleSaved(reply,for:change))
        XCTAssertEqual(restored["subtasks"],change.fields["subtasks"])
        XCTAssertEqual(TeamChecklist.token(try TeamChecklist.indexed(restored["subtasks"]).values.first?[TeamChecklist.key])?.version,3)
    }

}
