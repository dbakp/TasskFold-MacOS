import XCTest
@testable import TaskfoldCore

@MainActor final class TaskNotePreviewReadTests: XCTestCase {
    private func context(_ account: String = "A", generation: UUID = UUID(), session: UUID = UUID(), access: UUID = UUID()) -> TaskNotePreviewReadCache.Context {
        .init(workspace: .init(account: account, generation: generation), session: session, access: access)
    }
    private func expected(_ text: String, full: Bool) -> String {
        full ? NoteMarkup.plainText(text, includeLinkDestinations: true).trimmingCharacters(in: .whitespacesAndNewlines) : NoteMarkup.summary(text, includeLinkDestinations: true)
    }
    func testCompactAndAccessibilityTextMatchExistingFormattingAndDestinations() async {
        let cache = TaskNotePreviewReadCache(), c = context()
        let examples = ["", " \n\t ", "\n# Review\n\n**Approve** the [brief](https://example.invalid/brief).\n", "  Café 👨‍👩‍👧‍👦\r\nSecond line ", "```swift\nlet task = 1\n```", String(repeating:"Long **note** with https://example.invalid/section\n",count:100), "![unsupported](file:///private)\nKeep exact <tag> text"]
        for (n,text) in examples.enumerated() {
            for full in [false,true] {
                let result=cache.read(text,id:String(n),fullText:full,context:c)
                XCTAssertTrue(result.utf8.elementsEqual(expected(text,full:full).utf8))
            }
        }
        XCTAssertTrue(cache.read(examples[2],id:"2",fullText:true,context:c).contains("https://example.invalid/brief"))
    }
    func testRedrawsReuseOneResultAndChangedSameIDReadsFreshText() async {
        let cache=TaskNotePreviewReadCache(),c=context(),source=String(repeating:"**Prepare** the workshop.\n",count:30)
        let first=cache.read(source,id:"task",fullText:false,context:c)
        for _ in 0..<100 { XCTAssertEqual(cache.read(source,id:"task",fullText:false,context:c),first) }
        XCTAssertEqual(cache.computationCount,1)
        XCTAssertEqual(cache.read("New note",id:"task",fullText:false,context:c),"New note")
        XCTAssertEqual(cache.computationCount,2)
        XCTAssertEqual(cache.read("",id:"task",fullText:false,context:c),"");XCTAssertEqual(cache.count,0)
    }
    func testModesDoNotReplaceFullAccessibilityTextWithCompactSummary() async {
        let cache=TaskNotePreviewReadCache(),c=context(),source=String(repeating:"Readable full note. ",count:100)
        let compact=cache.read(source,id:"task",fullText:false,context:c),full=cache.read(source,id:"task",fullText:true,context:c)
        XCTAssertTrue(compact.hasSuffix("…"));XCTAssertEqual(full,source.trimmingCharacters(in:.whitespacesAndNewlines));XCTAssertGreaterThan(full.count,compact.count)
        _=cache.read(source,id:"task",fullText:false,context:c);_=cache.read(source,id:"task",fullText:true,context:c)
        XCTAssertEqual(cache.computationCount,2);XCTAssertEqual(cache.count,2)
    }
    func testCanonicalUnicodeAndEqualLengthReplacementsRemainExact() async {
        let cache=TaskNotePreviewReadCache(),c=context()
        for (a,b) in [("Caf\u{e9}","Cafe\u{301}"),("abcdefghi","abcxyzghi"),(String(repeating:"a",count:1000),String(repeating:"b",count:1000))] {
            let before=cache.computationCount
            XCTAssertTrue(cache.read(a,id:"task",fullText:true,context:c).utf8.elementsEqual(a.utf8))
            XCTAssertTrue(cache.read(b,id:"task",fullText:true,context:c).utf8.elementsEqual(b.utf8))
            XCTAssertEqual(cache.computationCount,before+2)
        }
    }
    func testEqualTextFromIndependentStorageIsSafeToReuse() async {
        let cache=TaskNotePreviewReadCache(),c=context(),a=String(repeating:"Note **content** café. ",count:30)
        let b=String(decoding:Array(a.utf8),as:UTF8.self)
        let first=cache.read(a,id:"task",fullText:false,context:c)
        XCTAssertEqual(cache.read(b,id:"task",fullText:false,context:c),first);XCTAssertEqual(cache.computationCount,1)
    }
    func testAccountGenerationSessionAndAccessChangesClearOldEntries() async {
        let cache=TaskNotePreviewReadCache(),c=context(),source="Private **preview**"
        let scopes=[c,context("B",generation:c.workspace.generation,session:c.session,access:c.access),context(generation:UUID(),session:c.session,access:c.access),context(generation:c.workspace.generation,session:UUID(),access:c.access),context(generation:c.workspace.generation,session:c.session,access:UUID())]
        for scope in scopes { _=cache.read(source,id:"task",fullText:false,context:scope);XCTAssertEqual(cache.count,1) }
        XCTAssertEqual(cache.computationCount,5);cache.clear();XCTAssertEqual(cache.count,0);XCTAssertEqual(cache.retainedTextBytes,0)
    }
    func testEntryAndTextByteLimitsEvictLeastRecentlyReadText() async {
        let cache=TaskNotePreviewReadCache(maximumEntries:2,maximumTextBytes:12),c=context()
        _=cache.read("one",id:"A",fullText:false,context:c);_=cache.read("two",id:"B",fullText:false,context:c);_=cache.read("one",id:"A",fullText:false,context:c)
        _=cache.read("six",id:"C",fullText:false,context:c);XCTAssertEqual(cache.count,2);XCTAssertEqual(cache.retainedTextBytes,12)
        _=cache.read("one",id:"A",fullText:false,context:c);XCTAssertEqual(cache.computationCount,3)
        _=cache.read("two",id:"B",fullText:false,context:c);XCTAssertEqual(cache.computationCount,4)
        XCTAssertEqual(cache.read("A note too large",id:"large",fullText:true,context:c),"A note too large");XCTAssertEqual(cache.count,2);XCTAssertEqual(cache.retainedTextBytes,12)
    }
    func testDisabledCachePreservesResultsWithoutRetainingText() async {
        let cache=TaskNotePreviewReadCache(maximumEntries:0),c=context()
        for _ in 0..<2 {XCTAssertEqual(cache.read("Text",id:"task",fullText:false,context:c),"Text")}
        XCTAssertEqual(cache.computationCount,2);XCTAssertEqual(cache.count,0);XCTAssertEqual(cache.retainedTextBytes,0)
    }
    func testRepeatedFormattingDiagnostic() async {
        let source=String(repeating:"# Workshop\n\nReview **contrast** and the [brief](https://example.invalid/brief).\n\n",count:32),cache=TaskNotePreviewReadCache(),c=context()
        for full in [false,true] {
            var check=0;let start=Date.timeIntervalSinceReferenceDate
            for _ in 0..<100 {check += expected(source,full:full).utf8.count}
            let old=(Date.timeIntervalSinceReferenceDate-start)*1000,now=Date.timeIntervalSinceReferenceDate
            var actual=0
            for _ in 0..<100 {actual += cache.read(source,id:"task",fullText:full,context:c).utf8.count}
            let retained=(Date.timeIntervalSinceReferenceDate-now)*1000
            XCTAssertEqual(actual,check)
            print("NOTE_ROW_DIAGNOSTIC full=\(full) baseline_ms=\(old) retained_ms=\(retained) rounds=100")
        }
        XCTAssertEqual(cache.computationCount,2)
    }
}
