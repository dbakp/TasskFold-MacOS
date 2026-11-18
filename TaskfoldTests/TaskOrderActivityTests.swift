import XCTest
@testable import TaskfoldCore

final class TaskOrderActivityTests: XCTestCase {
    let helper = TaskNodeActivityTests()
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
