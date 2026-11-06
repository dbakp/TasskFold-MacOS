import XCTest
@testable import TaskfoldCore

final class NoteSourceBindingTests: XCTestCase {
    func testCanonicalUnicodeURLSourcesAreDistinctEvenWhenSwiftStringsCompareEqual() throws {
        let a = "[Brief](https://example.invalid/caf\u{e9})"
        let b = "[Brief](https://example.invalid/cafe\u{301})"
        XCTAssertEqual(a,b)
        XCTAssertNotEqual(NoteMarkup.Source(a),NoteMarkup.Source(b))
        let first = try NoteMarkup.Prepared(a), second = try NoteMarkup.Prepared(b)
        let urls = { (reading: NoteMarkup.Prepared) in reading.inlineText.values.flatMap { $0.runs.compactMap { $0.link?.absoluteString } } }
        XCTAssertNotEqual(urls(first),urls(second))
        XCTAssertNotEqual(NoteMarkup.Source(first.source),NoteMarkup.Source(second.source))
    }
    func testCopiedAndIndependentExactSourcesRemainEqual() {
        let a = String(repeating:"# Café 👩🏽‍💻\n",count:100), b = String(decoding:Array(a.utf8),as:UTF8.self)
        XCTAssertEqual(NoteMarkup.Source(a),NoteMarkup.Source(a))
        XCTAssertEqual(NoteMarkup.Source(a),NoteMarkup.Source(b))
        XCTAssertEqual(NoteMarkup.Source(""),NoteMarkup.Source(""))
    }
    func testEqualLengthRevisionsAndLineEndingsInvalidateRetainedTargets() {
        for (a,b) in [("# First","# Other"),("# A\nParagraph","# A\r\nParagraph"),("# A ","# A\t")] {
            XCTAssertNotEqual(NoteMarkup.Source(a),NoteMarkup.Source(b))
        }
    }
    func testAsyncRevisedPreparationDoesNotMatchTheRetainedSource() async throws {
        let a = "# First\n\n[Read](https://example.invalid/a)", b = "# Last\n\n[Read](https://example.invalid/b)"
        let first = try await NoteMarkup.Prepared.load(a), second = try await NoteMarkup.Prepared.load(b)
        XCTAssertEqual(NoteMarkup.Source(first.source),NoteMarkup.Source(a))
        XCTAssertEqual(NoteMarkup.Source(second.source),NoteMarkup.Source(b))
        XCTAssertNotEqual(NoteMarkup.Source(first.source),NoteMarkup.Source(b))
        XCTAssertEqual(second.headings.map(\.title),["Last"])
    }
}
