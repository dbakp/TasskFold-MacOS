import XCTest
@testable import TaskfoldCore

final class PlannerTimelineTests:XCTestCase {
    private var calendar:Calendar {var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(identifier:"Europe/Copenhagen")!;return value}
    private var day:Date {Dates.parse("2026-10-21",calendar:calendar)!}
    private func task(_ id:String,_ time:String,_ minutes:Int?=nil)->Record {
        var row=Record(["id":.string(id),"title":.string(id),"due_date":.string("2026-10-21"),"due_time":.string(time)])
        if let minutes {row["duration_minutes"] = .number(Double(minutes))};return row
    }
    private func event(_ id:String,_ minute:Int,_ duration:Int,allDay:Bool=false)->PlannerEvent {
        let start=calendar.startOfDay(for:day).addingTimeInterval(Double(minute)*60)
        return PlannerEvent(id:id,calendarID:"synthetic-calendar",title:id,start:start,end:start.addingTimeInterval(Double(duration)*60),allDay:allDay)
    }
    func testCalendarAndTasksShareCollisionLanesWithoutChangingRecordsOrCapacity() throws {
        let tasks=[task("design","09:00",60),task("review","09:30",30)],events=[event("meeting",540,60)]
        let blocks=TaskPlanner.blocks(tasks,on:day,calendar:calendar),capacity=TaskPlanner.capacity(tasks,events:events,on:day,hours:WorkingHours(),calendar:calendar)
        let result=PlannerTimelineItem.layout(blocks:blocks,events:events,on:day,calendar:calendar)
        XCTAssertEqual(result.count,3);XCTAssertEqual(Set(result.map(\.lane)).count,3);XCTAssertTrue(result.allSatisfy{$0.laneCount==3})
        XCTAssertEqual(result.first?.id,"task:design")
        XCTAssertEqual(TaskPlanner.capacity(tasks,events:events,on:day,hours:WorkingHours(),calendar:calendar).busyMinutes,60)
        XCTAssertEqual(TaskPlanner.capacity(tasks,events:events,on:day,hours:WorkingHours(),calendar:calendar),capacity)
        let renderedTasks=result.compactMap{item->Record? in if case .task(let block)=item.content {return block.task};return nil}
        XCTAssertEqual(renderedTasks,tasks)
    }
    func testCalendarOverlapsReuseLanesAndIndependentLaterPlansStayFullWidth() {
        let result=PlannerTimelineItem.layout(blocks:[],events:[event("a",540,60),event("b",555,15),event("c",585,15),event("later",660,60)],on:day,calendar:calendar)
        XCTAssertEqual(result.map(\.lane),[0,1,1,0]);XCTAssertEqual(result.map(\.laneCount),[2,2,2,1])
        XCTAssertGreaterThanOrEqual(result[0].width(in:300),136);XCTAssertEqual(result.last?.width(in:300),296)
        XCTAssertEqual(result.map(\.id),PlannerTimelineItem.layout(blocks:[],events:[event("later",660,60),event("c",585,15),event("b",555,15),event("a",540,60)],on:day,calendar:calendar).map(\.id))
    }
    func testShortMeetingsAndUnknownEstimatesKeepVisualTargetsWithoutInventingBusyTime() {
        let tasks=[task("anchor","09:00")],events=[event("short",540,5),event("next",545,5)]
        let result=PlannerTimelineItem.layout(blocks:TaskPlanner.blocks(tasks,on:day,calendar:calendar),events:events,on:day,calendar:calendar)
        XCTAssertTrue(result.allSatisfy{$0.laneCount==3 && $0.renderLength==30})
        let capacity=TaskPlanner.capacity(tasks,events:events,on:day,hours:WorkingHours(),calendar:calendar)
        XCTAssertEqual(capacity.busyMinutes,10);XCTAssertEqual(capacity.estimatedMinutes,0);XCTAssertEqual(capacity.unknownTasks,1)
    }
    func testAllDayCalendarStaysOutsideTimedLanesAndStillCountsTowardCapacity() {
        let allDay=event("offsite",0,1440,allDay:true),task=task("work","09:00",60)
        let result=PlannerTimelineItem.layout(blocks:TaskPlanner.blocks([task],on:day,calendar:calendar),events:[allDay],on:day,calendar:calendar)
        XCTAssertEqual(result.map(\.id),["task:work"]);XCTAssertEqual(result.first?.laneCount,1)
        XCTAssertEqual(TaskPlanner.capacity([task],events:[allDay],on:day,hours:WorkingHours(),calendar:calendar).busyMinutes,480)
    }
    func testMidnightClippingInvalidEventsAndCrossKindIdentity() {
        let result=PlannerTimelineItem.layout(blocks:TaskPlanner.blocks([task("same","09:00",30)],on:day,calendar:calendar),events:[event("same",540,30),event("carry",-60,90),event("ended",-60,60),event("tomorrow",1440,60),event("invalid",600,-5)],on:day,calendar:calendar)
        XCTAssertEqual(Set(result.map(\.id)),["task:same","calendar:same","calendar:carry"])
        XCTAssertEqual(result.first?.minute,0);XCTAssertEqual(result.first?.length,30)
    }
    func testDSTFoldsKeepAbsolutePositionsAndDayBoundaries() {
        let day=Dates.parse("2026-10-25",calendar:calendar)!,first=TaskPlanning.instant("2026-10-25T00:30:00Z")!,second=TaskPlanning.instant("2026-10-25T01:30:00Z")!
        let events=[first,second].enumerated().map{index,date in PlannerEvent(id:String(index),calendarID:"fixture",start:date,end:date.addingTimeInterval(900))}
        let result=PlannerTimelineItem.layout(blocks:[],events:events,on:day,calendar:calendar)
        XCTAssertEqual(result.map(\.minute),[150,210]);XCTAssertTrue(result.allSatisfy{$0.laneCount==1})
    }
    func testDenseVisualIntervalsNeverShareAColumnOrCollapseToUnreadableWidths() {
        let events=(0..<70).map {event(String($0),480+($0*17)%180,1+($0*23)%120)}
        let result=PlannerTimelineItem.layout(blocks:[],events:events,on:day,calendar:calendar)
        for a in result.indices {
            XCTAssertGreaterThanOrEqual(result[a].width(in:280),136)
            for b in result.indices where b>a && result[a].minute<result[b].renderEnd && result[a].renderEnd>result[b].minute {
                XCTAssertNotEqual(result[a].lane,result[b].lane)
            }
        }
    }
}
