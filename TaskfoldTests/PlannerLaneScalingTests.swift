import XCTest
@testable import TaskfoldCore

final class PlannerLaneScalingTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    private func events(_ count: Int, day: Date, seed: UInt64, dense: Bool = false) -> [PlannerEvent] {
        var state = seed
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 32) & 0x7fffffff) }
        let start = calendar.startOfDay(for: day)
        return (0..<count).map { i in
            let minute = dense ? 540 : next() % 1800 - 180
            let length = dense ? 300 : next() % 300 + 1
            return PlannerEvent(id: "event-\(i)", calendarID: "synthetic", start: start.addingTimeInterval(Double(minute) * 60), end: start.addingTimeInterval(Double(minute + length) * 60), allDay: !dense && i % 29 == 0)
        }
    }
    private func assertSame(_ actual: [PlannerTimelineItem], _ expected: [PlannerTimelineItem], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map(\.minute), expected.map(\.minute), file: file, line: line)
        XCTAssertEqual(actual.map(\.length), expected.map(\.length), file: file, line: line)
        XCTAssertEqual(actual.map(\.lane), expected.map(\.lane), file: file, line: line)
        XCTAssertEqual(actual.map(\.laneCount), expected.map(\.laneCount), file: file, line: line)
        for (a, b) in zip(actual, expected) {
            switch (a.content, b.content) {
            case (.task(let x), .task(let y)): XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(x.task.fields), .object(y.task.fields)), file: file, line: line)
            case (.event(let x), .event(let y)): XCTAssertEqual(x, y, file: file, line: line)
            default: XCTFail("Content changed", file: file, line: line)
            }
        }
    }
    func testMatchesPriorLayoutAcrossMixedInputsAndClockChanges() {
        for date in ["2026-10-21", "2026-10-25", "2026-03-29"] {
            let day = Dates.parse(date, calendar: calendar)!
            for seed in 1...80 {
                var input = events(80, day: day, seed: UInt64(seed))
                input.append(input[3]) // Existing duplicate identity behavior.
                let rows = (0..<24).map { i -> Record in
                    Record(["id": .string("task-\(i)"), "due_date": .string(date), "due_time": .string(String(format: "%02d:%02d", (i * 7) % 24, (i * 13) % 60)), "duration_minutes": i % 3 == 0 ? .null : .number(Double((i * 23) % 240 + 1))])
                }
                let blocks = TaskPlanner.blocks(rows, on: day, calendar: calendar)
                assertSame(PlannerTimelineItem.layout(blocks: blocks, events: input, on: day, calendar: calendar), reference(blocks: blocks, events: input, on: day, calendar: calendar))
            }
        }
    }
    func testReusesLowestAvailableColumnRatherThanEarliestEndingColumn() {
        let day = Dates.parse("2026-10-21", calendar: calendar)!, start = calendar.startOfDay(for: Dates.parse("2026-10-21", calendar: calendar)!)
        let spans = [(0, 300), (1, 100), (2, 50), (101, 30), (301, 30)]
        let input = spans.enumerated().map { i, span in PlannerEvent(id: "e\(i)", calendarID: "synthetic", start: start.addingTimeInterval(Double(span.0) * 60), end: start.addingTimeInterval(Double(span.0 + span.1) * 60)) }
        let result = PlannerTimelineItem.layout(blocks: [], events: input, on: day, calendar: calendar)
        XCTAssertEqual(result.map(\.lane), [0, 1, 2, 1, 0])
        XCTAssertEqual(result.map(\.laneCount), [3, 3, 3, 3, 1])
        assertSame(result, reference(blocks: [], events: input, on: day, calendar: calendar))
    }
    func testDenseLayoutDiagnosticPreservesEveryColumn() throws {
        let day = Dates.parse("2026-10-21", calendar: calendar)!
        let input = events(4096, day: day, seed: 42, dense: true)
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for _ in 0..<5 {
            var start = Date.timeIntervalSinceReferenceDate
            let expected = reference(blocks: [], events: input, on: day, calendar: calendar)
            oldTimes.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
            start = Date.timeIntervalSinceReferenceDate
            let result = PlannerTimelineItem.layout(blocks: [], events: input, on: day, calendar: calendar)
            newTimes.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
            assertSame(result, expected)
            XCTAssertEqual(Set(result.map(\.lane)).count, 4096)
            XCTAssertTrue(result.allSatisfy { $0.laneCount == 4096 })
        }
        let report: [String: Any] = ["scope": "SwiftPM Debug on this Mac; 4096 synthetic overlapping events; layout only, no UI/FPS claim", "referenceMilliseconds": oldTimes, "currentMilliseconds": newTimes, "referenceMedianMilliseconds": oldTimes.sorted()[2], "currentMedianMilliseconds": newTimes.sorted()[2]]
        print("PLANNER_LANE_DIAGNOSTIC " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
    private func reference(blocks:[PlannerBlock],events:[PlannerEvent],on day:Date,calendar:Calendar = .current)->[PlannerTimelineItem] {
        func order(_ item: PlannerTimelineItem) -> Int { if case .task = item.content { return 0 }; return 1 }
        guard let bounds=calendar.dateInterval(of:.day,for:day) else {return []}
        var seen=Set<String>()
        var raw=blocks.map {PlannerTimelineItem(content:.task($0),minute:$0.minute,length:$0.length)}
        raw += events.compactMap {event in
            guard !event.allDay,event.start.timeIntervalSince1970.isFinite,event.end.timeIntervalSince1970.isFinite,event.end>event.start,event.start<bounds.end,event.end>bounds.start else {return nil}
            let start=max(event.start,bounds.start),end=min(event.end,bounds.end)
            return PlannerTimelineItem(content:.event(event),minute:start.timeIntervalSince(bounds.start)/60,length:end.timeIntervalSince(start)/60)
        }
        raw=raw.filter {seen.insert($0.id).inserted}.sorted {
            if $0.minute != $1.minute {return $0.minute<$1.minute}
            if $0.renderEnd != $1.renderEnd {return $0.renderEnd>$1.renderEnd}
            if order($0) != order($1) {return order($0)<order($1)}
            return $0.id<$1.id
        }
        var result:[PlannerTimelineItem]=[],cluster:[PlannerTimelineItem]=[],ends:[Double]=[],clusterEnd = -Double.infinity
        func finish() {for var item in cluster {item.laneCount=ends.count;result.append(item)};cluster=[];ends=[];clusterEnd = -Double.infinity}
        for var item in raw {
            if item.minute>=clusterEnd {finish()}
            let lane=ends.firstIndex(where:{$0<=item.minute}) ?? ends.count
            if lane==ends.count {ends.append(item.renderEnd)} else {ends[lane]=item.renderEnd}
            item.lane=lane;cluster.append(item);clusterEnd=max(clusterEnd,item.renderEnd)
        }
        finish();return result
    }
}
