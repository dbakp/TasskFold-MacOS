import XCTest
@testable import TaskfoldCore

final class TaskOrderActivityTests: XCTestCase {
    let helper = TaskNodeActivityTests()
    func testOneRootListEventDoesNotClaimShiftedPeersOrCompletion() throws {
        let h=helper,b=h.root([h.node("a"),h.node("b"),h.node("c")]),a=h.root([h.node("c"),h.node("a"),h.node("b")])
        let rows=h.rows(b,a),e=try XCTUnwrap(rows.first.flatMap(TaskNodeActivity.init))
        XCTAssertEqual(rows.count,1);XCTAssertEqual(e.kinds,[.reordered]);XCTAssertEqual(e.ordering?.before,["a","b","c"]);XCTAssertEqual(e.ordering?.after,["c","a","b"])
        XCTAssertEqual(e.nodeKey,"");XCTAssertEqual(e.beforePath,[]);XCTAssertEqual(e.afterPath,[]);XCTAssertFalse(e.workBefore || e.workAfter)
        XCTAssertEqual(WorkActivity.child(e).title,"Order changed");XCTAssertEqual(e.recordedAt,e.effectiveAt)
        XCTAssertEqual(e.currentTask(tasks:[a],projects:[Record(["id":.string(h.project)])],account:h.owner)?.id,h.rootID)
        XCTAssertNil(e.currentTask(tasks:[a],projects:[],account:h.owner))
    }
    func testInsertionAndRemovalDoNotDescribeShiftedPeersAsReordered() {
        let h=helper,b=h.root([h.node("a"),h.node("b")]),inserted=h.root([h.node("new"),h.node("a"),h.node("b")])
        XCTAssertEqual(h.events(b,inserted).map(\.kinds),[[.created]])
        XCTAssertEqual(h.events(inserted,b).map(\.kinds),[[.deleted]])
    }
    func testConcurrentInsertionStillRetainsRealSurvivorReorder() throws {
        let h=helper,b=h.root([h.node("a"),h.node("b"),h.node("c")]),a=h.root([h.node("new"),h.node("c"),h.node("a")])
        let values=h.events(b,a);XCTAssertEqual(values.count,3)
        let order=try XCTUnwrap(values.first{$0.isOrdering})
        XCTAssertEqual(order.ordering?.before,["a","c"]);XCTAssertEqual(order.ordering?.after,["c","a"])
    }
    func testNestedListsAndReparentingHaveSeparateMeaning() throws {
        let h=helper,b=h.root([h.node("a"),h.node("b"),h.node("phase",heading:true,children:[h.node("x"),h.node("y")])])
        let a=h.root([h.node("b"),h.node("phase",heading:true,children:[h.node("a"),h.node("x"),h.node("y")])])
        XCTAssertFalse(h.events(b,a).contains{$0.isOrdering})
        let reordered=h.root([h.node("b"),h.node("phase",heading:true,children:[h.node("y"),h.node("a"),h.node("x")])])
        let e=try XCTUnwrap(h.events(a,reordered).first)
        XCTAssertEqual(e.beforePath,["phase"]);XCTAssertEqual(e.nodeKey,"phase");XCTAssertEqual(e.ordering?.after,["y","a","x"])
        XCTAssertEqual(e.currentTask(tasks:[reordered],projects:[Record(["id":.string(h.project)])],account:h.owner)?.title,"phase")
    }
    func testRootGenerationChangeCannotClaimAnOrderContinuity() {
        let h=helper,b=h.root([h.node("a"),h.node("b")]);var a=h.root([h.node("b"),h.node("a")]);a["task_generation"] = .string(UUID().uuidString)
        XCTAssertFalse(h.events(b,a).contains{$0.isOrdering})
    }
    func testPrivateFieldsAreNeverOrderingMetadata() throws {
        let h=helper;var a=h.node("a");a["title"] = .string("Private title");a["description"] = .string("Private note")
        let b=h.root([a,h.node("b")]),after=h.root([h.node("b"),a]),saved=h.rows(b,after)
        let bytes=String(decoding:try TaskfoldJSONEncoder().encode(saved),as:UTF8.self)
        XCTAssertFalse(bytes.contains("Private title"));XCTAssertFalse(bytes.contains("Private note"))
    }
    func testOrderingDoesNotReplaceOrRetimestampCompletionCredit() throws {
        let h=helper,b=h.root([h.node("a"),h.node("b")]),done=h.complete(b,"a"),completed=h.rows(b,done)
        var reordered=done;reordered["subtasks"] = .array(Array(done["subtasks"].list.reversed()))
        let order=h.rows(done,reordered,sequence:1),epoch=[Record(["id":.string("current"),"recorded_from":.string("2026-10-01T00:00:00Z")])]
        let original=ChildWorkReading(.init(rows:completed,epoch:epoch),now:h.now).credits()
        XCTAssertEqual(ChildWorkReading(.init(rows:completed+order,epoch:epoch),now:h.now).credits(),original)
        XCTAssertTrue(ChildWorkReading(.init(rows:order,epoch:epoch),now:h.now).credits().isEmpty)
    }
    func testUndoRetryAndCoverageAreBoundToTheMutationAndAccount() throws {
        let h=helper,b=h.root([h.node("a"),h.node("b")]),a=h.root([h.node("b"),h.node("a")]),id=UUID()
        var snapshot=Snapshot(tables:[TaskNodeActivity.epochTable:[Record(["id":.string("current"),"recorded_from":.string("2026-10-01T00:00:00Z")])]])
        let mutation=h.change(b,a,id:id)
        TaskNodeActivity.recordLocal(mutation,before:b,after:a,snapshot:&snapshot,account:h.owner,now:h.now)
        let saved=snapshot
        TaskNodeActivity.recordLocal(mutation,before:b,after:a,snapshot:&snapshot,account:h.owner,now:h.now.addingTimeInterval(60));XCTAssertEqual(snapshot,saved)
        let history=ChildWorkHistory(rows:snapshot.tables[TaskNodeActivity.table],epoch:snapshot.tables[TaskNodeActivity.epochTable])
        XCTAssertEqual(history.orderRecordedFrom,h.now);XCTAssertNil(history.fieldRecordedFrom)
        XCTAssertEqual(h.events(a,b).first?.ordering?.after,["a","b"])
        var foreign=Snapshot();TaskNodeActivity.recordLocal(mutation,before:b,after:a,snapshot:&foreign,account:h.project,now:h.now);XCTAssertNil(foreign.tables[TaskNodeActivity.table])
        var modern=snapshot.tables[TaskNodeActivity.epochTable]![0];modern["field_recorded_from"] = .string("2026-10-31T10:00:00Z");XCTAssertTrue(TaskNodeActivity.validEpoch([modern]))
        modern["order_recorded_from"] = .string("bad");XCTAssertFalse(TaskNodeActivity.validEpoch([modern]))
    }
    func testStrictOrderingReaderRejectsAmbiguityAndFalseCredit() throws {
        let h=helper,b=h.root([h.node("a"),h.node("b")]),a=h.root([h.node("b"),h.node("a")]),good=try XCTUnwrap(h.rows(b,a).first)
        for fields:[String:JSON] in [
            ["format_version":.number(1)], ["order_context":.null],
            ["order_context":.object(["before":.array([.string("a"),.string("b")]),"after":.array([.string("a"),.string("b")])])],
            ["order_context":.object(["before":.array([.string("a"),.string("a")]),"after":.array([.string("b"),.string("a")])])],
            ["order_context":.object(["before":.array([.string("a"),.string("b")]),"after":.array([.string("b"),.string("x")])])],
            ["kinds":.array([.string("completed")])], ["work_after":.bool(true)], ["completion_version":.number(1)],
            ["node_key":.string("missing")], ["changed_fields":.array([.string("title")])], ["effective_at":.string("2026-10-01T00:00:00Z")]
        ] {var row=good;for(k,v) in fields {row[k]=v};XCTAssertNil(TaskNodeActivity(row:row),fields.description)}
        var legacy=h.rows(nil,b)[0];legacy["order_context"] = good["order_context"];XCTAssertNil(TaskNodeActivity(row:legacy))
    }

    func testActualServerOrderingRowsDecodeWithoutCompletionCredit() throws {
        struct Fixture: Decodable { let epoch: [Record]; let events: [Record] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"child-order-activity-v3",withExtension:"json",subdirectory:"Fixtures"))
        let fixture=try TaskfoldJSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        let parsed=fixture.events.compactMap(TaskNodeActivity.init)
        XCTAssertEqual(fixture.events.count,24);XCTAssertEqual(parsed.count,fixture.events.count)
        XCTAssertEqual(parsed.filter(\.isOrdering).count,6)
        let history=ChildWorkHistory(rows:fixture.events,epoch:fixture.epoch)
        XCTAssertNotNil(history.orderRecordedFrom);XCTAssertNotNil(history.fieldRecordedFrom)
        let reading=ChildWorkReading(history,now:Date.distantFuture)
        XCTAssertFalse(reading.incomplete);XCTAssertEqual(reading.malformed,0);XCTAssertTrue(reading.credits().isEmpty)
        XCTAssertTrue(parsed.filter(\.isOrdering).allSatisfy{WorkActivity.child($0).title=="Order changed"})
    }
}
