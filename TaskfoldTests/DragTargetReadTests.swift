import Foundation
import XCTest
@testable import TaskfoldCore

final class DragTargetReadTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar { var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:zone)!;return c }
    private func row(_ id: String,_ p: Int=4,day:String="2026-11-07",done:Bool=false)->Record { Record(["id":.string(id),"priority":.number(Double(p)),"due_date":.string(day),"completed":.bool(done)]) }
    private let generation=UUID(), snapshot=UUID(), access=UUID(), presentation=UUID(), session=UUID()
    private func context(account:String="local",generation:UUID?=nil,snapshot:UUID?=nil,access:UUID?=nil,presentation:UUID?=nil,session:UUID?=nil,zone:String="UTC",manual:Bool=true,readable:Bool=true)->DayDragTargetRead.Context {
        .init(workspace:.init(account:account,generation:generation ?? self.generation),snapshot:snapshot ?? self.snapshot,access:access ?? self.access,presentation:presentation ?? self.presentation,session:session ?? self.session,timeZone:calendar(zone).timeZone.identifier,manual:manual,readable:readable)
    }
    private func exact(_ a:String?,_ b:String?,file:StaticString=#filePath,line:UInt=#line){XCTAssertEqual(a.map{Array($0.utf8)},b.map{Array($0.utf8)},file:file,line:line)}
    private func legacy(_ source:[Record],dragged:String,before:String?,day:String,calendar:Calendar,ids:[String]=[],manual:Bool=true)->String? {
        guard let current=source.first(where:{$0.id==dragged}) else{return before}
        let rows=source.filter{!$0.completed && TaskPlanner.plannedDay($0,calendar:calendar)==day}
        let ordered=manual ? DayPlacement.arranged(rows,ids:ids) : rows
        return DayPlacement.constrained(before:before,priority:current.priority,in:ordered.filter{$0.id != dragged})
    }
    func testBandAnchorsMatchLegacyForSortedUnsortedExcludedAndDuplicateIdentities(){
        let base=[row("a",1),row("b",4),row("c",2),row("d",3),row("dup",1),row("dup",4),row("",2),row("é",3),row("e\u{301}",1)]
        for input in [base,Array(base.reversed()),Array(base.dropFirst(3))+Array(base.prefix(3))] {
            for excluded in [Set<String>(),Set(["a","d"]),Set(["dup","é"])] {
                let rows=input.filter{!excluded.contains($0.id)},read=TaskPriorityBandRead(input,excluding:excluded)
                for p in -1...6 {for before in [nil,"a","b","c","d","dup","","é","e\u{301}","missing"] as [String?] {
                    exact(read.constrained(before:before,priority:p),DayPlacement.constrained(before:before,priority:p,in:rows))
                }}
            }
        }
    }
    func testEmptyBandAndInvalidStoredPrioritiesKeepExistingRules(){
        var bad=row("bad");bad["priority"] = .string("unknown")
        var zero=row("zero");zero["priority"] = .number(0)
        for rows in [[],[bad,zero,row("high",99),row("low",-5)]] {
            let read=TaskPriorityBandRead(rows)
            for p in 0...5 {for id in [nil,"bad","zero","high","low"] as [String?] {exact(read.constrained(before:id,priority:p),DayPlacement.constrained(before:id,priority:p,in:rows))}}
        }
    }
    func testRepeatedTargetsReuseCurrentSourceAndEachDestinationOrder() {
        let source=[row("drag",2),row("a",1),row("b",3),row("c",2,day:"2026-11-08"),row("done",1,done:true)]
        let read=DayDragTargetRead(draggedID:"drag"),c=calendar(),ctx=context(),ids=["b","a"]
        var loads=0,orders=0
        for n in 0..<100 {
            let day=n%2==0 ? "2026-11-07":"2026-11-08",before=n%3==0 ? "a":nil
            let actual=read.constrained(before:before,day:day,context:ctx,calendar:c,rows:{loads+=1;return source},order:{rows,_ in orders+=1;return DayPlacement.arranged(rows,ids:ids)})
            exact(actual,legacy(source,dragged:"drag",before:before,day:day,calendar:c,ids:ids))
        }
        XCTAssertEqual(loads,1);XCTAssertEqual(orders,2);XCTAssertEqual(read.sourceReads,1);XCTAssertEqual(read.destinationReads,2);XCTAssertEqual(read.targetReads,100)
    }
    func testEveryWorkspaceSourceAccessPresentationSessionZoneAndSortChangeRefreshes() {
        let source=[row("drag",2),row("a",1),row("b",3)]
        let contexts=[context(account:"other"),context(generation:UUID()),context(snapshot:UUID()),context(access:UUID()),context(presentation:UUID()),context(session:UUID()),context(zone:"America/New_York"),context(manual:false)]
        for ctx in contexts {
            let read=DayDragTargetRead(draggedID:"drag")
            var loads=0
            _=read.constrained(before:nil,day:"2026-11-07",context:context(),calendar:calendar(),rows:{loads+=1;return source},order:{rows,_ in rows})
            let c=calendar(ctx.timeZone)
            exact(read.constrained(before:"a",day:"2026-11-07",context:ctx,calendar:c,rows:{loads+=1;return source},order:{rows,_ in ctx.manual ? DayPlacement.arranged(rows,ids:[]):rows}),legacy(source,dragged:"drag",before:"a",day:"2026-11-07",calendar:c,manual:ctx.manual))
            XCTAssertEqual(loads,2);XCTAssertEqual(read.sourceReads,2);XCTAssertEqual(read.destinationReads,2)
        }
    }
    func testUnreadableAndMismatchedCalendarClearWithoutLoadingPrivateRows(){
        let read=DayDragTargetRead(draggedID:"drag"),c=calendar(),rows=[row("drag",2),row("private",3)]
        _=read.constrained(before:nil,day:"2026-11-07",context:context(),calendar:c,rows:{rows},order:{rows,_ in rows})
        for ctx in [context(readable:false),context(zone:"Europe/Copenhagen")] {
            exact(read.constrained(before:"raw",day:"2026-11-07",context:ctx,calendar:c,rows:{XCTFail("Unavailable source read");return rows},order:{_,_ in XCTFail("Unavailable order read");return []}),"raw")
        }
        let fresh=[row("drag",1),row("replacement",2)]
        exact(read.constrained(before:nil,day:"2026-11-07",context:context(),calendar:c,rows:{fresh},order:{rows,_ in rows}),"replacement")
        XCTAssertEqual(read.sourceReads,2)
    }
    func testChangedDatesCompletionPriorityRemovalAndManualOrderUseNewSource(){
        var source=[row("drag",2),row("a",1),row("b",3),row("c",2)],ids=["c","a","b"]
        let read=DayDragTargetRead(draggedID:"drag"),c=calendar()
        for step in 0..<6 {
            if step==1 {source[1]["due_date"] = .string("2026-11-08")}
            if step==2 {source[2]["completed"] = .bool(true)}
            if step==3 {source[0]["priority"] = .number(4)}
            if step==4 {ids.reverse()}
            if step==5 {source.removeFirst()}
            for day in ["2026-11-07","2026-11-08"] {
                let ctx=context(snapshot:UUID())
                exact(read.constrained(before:"a",day:day,context:ctx,calendar:c,rows:{source},order:{rows,_ in DayPlacement.arranged(rows,ids:ids)}),legacy(source,dragged:"drag",before:"a",day:day,calendar:c,ids:ids))
            }
        }
    }
    func testSourceMissingAndSourceReturningNeverReuseOldPriority(){
        let read=DayDragTargetRead(draggedID:"drag"),c=calendar()
        exact(read.constrained(before:"raw",day:"2026-11-07",context:context(),calendar:c,rows:{[row("other",1)]},order:{rows,_ in rows}),"raw")
        exact(read.constrained(before:nil,day:"2026-11-07",context:context(snapshot:UUID()),calendar:c,rows:{[row("drag",2),row("other",3)]},order:{rows,_ in rows}),"other")
        read.clear()
        exact(read.constrained(before:nil,day:"2026-11-07",context:context(),calendar:c,rows:{[row("drag",4),row("other",3)]},order:{rows,_ in rows}),nil)
        XCTAssertEqual(read.sourceReads,3)
    }
    func testTravelChangesFixedTaskDestinationWithoutLosingSourceValues() throws {
        var fixed=row("fixed",3);fixed["due_time"] = .string("23:30");fixed["time_zone"] = .string("UTC");fixed["scheduled_at"] = .string("2026-11-07T23:30:00Z")
        fixed["future"] = try TaskfoldJSONDecoder().decode(JSON.self,from:Data("9007199254740993".utf8))
        let source=[row("drag",2),fixed],read=DayDragTargetRead(draggedID:"drag"),encoder=TaskfoldJSONEncoder();encoder.outputFormatting = .sortedKeys
        let original=try encoder.encode(source)
        for zone in ["UTC","Europe/Copenhagen","America/New_York"] {for day in ["2026-11-07","2026-11-08"] {
            let ctx=context(zone:zone),c=calendar(zone)
            exact(read.constrained(before:nil,day:day,context:ctx,calendar:c,rows:{source},order:{rows,_ in rows}),legacy(source,dragged:"drag",before:nil,day:day,calendar:c))
        }}
        XCTAssertEqual(try encoder.encode(source),original)
    }
    func testPointerWorkloadKeepsExactSlotsAndRecordsTiming(){
        let c=calendar(),ctx=context(),ids=["r-7","r-3"]
        let source=[row("drag",2)]+(0..<120).map{n->Record in
            var r=row("r-\(n)",1+n%4,day:String(format:"2026-11-%02d",7+n%14));r["due_time"] = .string("09:30");r["time_zone"] = .string("UTC");r["scheduled_at"] = .string(String(format:"2026-11-%02dT09:30:00Z",7+n%14));return r
        }
        var before:[Double]=[],after:[Double]=[]
        for _ in 0..<3 {
            var old:[String?]=[],fresh:[String?]=[];let a=Date()
            for n in 0..<24 {old.append(legacy(source,dragged:"drag",before:n%3==0 ? "r-7":nil,day:n%2==0 ? "2026-11-07":"2026-11-08",calendar:c,ids:ids))}
            let b=Date(),read=DayDragTargetRead(draggedID:"drag")
            for n in 0..<24 {fresh.append(read.constrained(before:n%3==0 ? "r-7":nil,day:n%2==0 ? "2026-11-07":"2026-11-08",context:ctx,calendar:c,rows:{source},order:{rows,_ in DayPlacement.arranged(rows,ids:ids)}))}
            let end=Date();XCTAssertEqual(old,fresh);XCTAssertEqual(read.sourceReads,1);XCTAssertEqual(read.destinationReads,2)
            before.append(b.timeIntervalSince(a));after.append(end.timeIntervalSince(b))
        }
        print("DRAG_TARGET_TIMING rows=121 updates=24 legacy=\(before) reused=\(after)")
    }
}
