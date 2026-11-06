import XCTest
@testable import TaskfoldCore

final class ConversationTimelineTests: XCTestCase {
    let account = UUID(uuidString:"ce310000-0000-4000-8000-000000000001")!
    let task = UUID(uuidString:"ce310000-0000-4000-8000-000000000002")!
    let generation = UUID(uuidString:"ce310000-0000-4000-8000-000000000003")!
    let project = UUID(uuidString:"ce310000-0000-4000-8000-000000000004")!
    func text(_ stamp:String,id:UUID=UUID(),updated:String?=nil,deleted:Bool=false,target:UUID?=nil) throws -> SharedComment {
        try XCTUnwrap(SharedComment(Record(["id":.string(id.uuidString.lowercased()),"task_id":.string((target ?? task).uuidString.lowercased()),"task_generation":.string(generation.uuidString.lowercased()),"project_id":.string(project.uuidString.lowercased()),"author_id":.string(account.uuidString.lowercased()),"body":.string(deleted ? "":"Keep the cafe\u{301} notes\nمراجعة 🪴"),"mention_ids":.array([]),"revision":.number(1),"created_at":.string(stamp),"updated_at":.string(updated ?? stamp),"deleted_at":deleted ? .string(stamp):.null])))
    }
    func audio(_ stamp:String,id:UUID=UUID(),reader:UUID?=nil,target:UUID?=nil,project:UUID?=nil) throws -> AudioCommentRemote {
        let account=reader ?? account,target=try AudioCommentTarget(task:target ?? task,generation:generation,project:project ?? self.project)
        let descriptor=try AudioCommentDescriptor(byteCount:100,milliseconds:1000,sha256:String(repeating:"a",count:64))
        let publication=try AudioCommentPublication(account:account,target:target,caption:"Literal audio\nمراجعة 🪴",descriptor:descriptor,comment:id)
        var fields=publication.record.fields;fields.removeValue(forKey:"version")
        fields["protocol"] = .number(1);fields["author_id"] = .string(account.uuidString.lowercased());fields["state"] = .string("published");fields["reserved_at"] = .string("2026-10-28T00:00:00Z");fields["expires_at"] = .string("2026-10-29T00:00:00Z");fields["published_at"] = .string(stamp)
        return try .init(record:Record(fields),account:account,target:target)
    }
    func merge(_ text:[SharedComment],_ audio:[AudioCommentRemote]) -> [ConversationTimelineEntry] {
        ConversationTimelineEntry.merge(text:text,audio:audio,account:account.uuidString.lowercased(),taskID:task.uuidString.lowercased(),generation:generation.uuidString.lowercased(),project:project.uuidString.lowercased())
    }
    func testTextAndAudioInterleaveByOriginalEventTime() throws {
        let first=try text("2026-10-28T12:00:00Z"),middle=try audio("2026-10-28T12:01:00Z"),last=try text("2026-10-28T12:02:00Z")
        XCTAssertEqual(merge([last,first],[middle]),[.text(first),.audio(middle),.text(last)])
    }
    func testTextEditDoesNotMoveTheOriginalEvent() throws {
        let first=try text("2026-10-28T12:00:00Z",updated:"2026-10-28T23:00:00Z"),second=try audio("2026-10-28T12:01:00Z")
        XCTAssertEqual(merge([first],[second]),[.text(first),.audio(second)])
    }
    func testMicrosecondsSurviveFoundationMillisecondTruncation() throws {
        let id1=UUID(uuidString:"ce310000-0000-4000-8000-000000000011")!,id2=UUID(uuidString:"ce310000-0000-4000-8000-000000000012")!
        let earlier=try text("2026-10-28T12:00:00.123455Z",id:id2),later=try audio("2026-10-28T12:00:00.123456Z",id:id1)
        XCTAssertEqual(merge([earlier],[later]),[.text(earlier),.audio(later)])
    }
    func testOffsetsAndFractionWidthsRepresentEquivalentInstants() throws {
        let a=try text("2026-10-28T14:00:00.123456+02:00"),b=try audio("2026-10-28T12:00:00.123456Z")
        let values=merge([a],[b]);XCTAssertEqual(values.map(\.id),values.map(\.id).sorted())
        let c=try text("2026-10-28T12:00:00.1Z"),d=try audio("2026-10-28T12:00:00.100000+00:00")
        XCTAssertEqual(merge([c],[d]).map(\.id),merge([c],[d]).map(\.id).sorted())
    }
    func testEqualUUIDsInDifferentMediaDoNotCollide() throws {
        let id=UUID(),a=try text("2026-10-28T12:00:00Z",id:id),b=try audio("2026-10-28T12:00:00Z",id:id)
        let values=merge([a],[b]);XCTAssertEqual(values.count,2);XCTAssertEqual(Set(values.map(\.id)).count,2)
        XCTAssertEqual(values,merge([a],[b]))
    }
    func testWrongTaskAccountProjectAndGenerationAreExcluded() throws {
        let a=try text("2026-10-28T12:00:00Z",target:UUID()),b=try audio("2026-10-28T12:00:00Z",reader:UUID()),c=try audio("2026-10-28T12:00:00Z",target:UUID()),d=try audio("2026-10-28T12:00:00Z",project:UUID())
        XCTAssertTrue(merge([a],[b,c,d]).isEmpty)
        let valid=try text("2026-10-28T12:00:00Z"),recording=try audio("2026-10-28T12:00:00Z")
        XCTAssertTrue(ConversationTimelineEntry.merge(text:[valid],audio:[recording],account:account.uuidString.lowercased(),taskID:task.uuidString.lowercased(),generation:UUID().uuidString.lowercased(),project:project.uuidString.lowercased()).isEmpty)
    }
    func testRemovedTextIsExcludedAndLiteralCaptionsUnchanged() throws {
        let removed=try text("2026-10-28T12:00:00Z",deleted:true),a=try text("2026-10-28T12:01:00Z"),b=try audio("2026-10-28T12:02:00Z")
        XCTAssertEqual(merge([removed,a],[b]),[.text(a),.audio(b)])
        guard case .text(let returned)=merge([a],[b]).first else {return XCTFail("Missing literal text")}
        XCTAssertTrue(returned.body.utf8.elementsEqual(a.body.utf8))
    }
    func testNewlyLoadedPagesMergeWithoutChangingExistingIdentities() throws {
        let a=try text("2026-10-28T12:01:00Z"),b=try audio("2026-10-28T12:02:00Z"),earlier=try text("2026-10-28T12:00:00Z"),later=try audio("2026-10-28T12:03:00Z")
        XCTAssertEqual(merge([a,earlier],[later,b]),[.text(earlier),.text(a),.audio(b),.audio(later)])
        XCTAssertEqual(merge([a],[b]).map(\.id),merge([a,earlier],[later,b]).filter{$0 != .text(earlier) && $0 != .audio(later)}.map(\.id))
    }
}
