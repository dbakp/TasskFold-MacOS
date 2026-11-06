import XCTest
@testable import TaskfoldCore

final class NoteInlineFormattingTests: XCTestCase {
    func testInlineToolsRefuseGrowthPastReaderLimit() {
        let source = String(repeating: "x", count: NoteMarkup.maximumBytes)
        for style in [NoteFormatting.Style.bold, .italic, .code, .link] {
            XCTAssertThrowsError(try NoteFormatting.apply(style, to: source, selection: NSRange(location: 0, length: 1), url: "https://example.com/guide"), style.rawValue)
        }
        XCTAssertEqual(source.utf8.count, NoteMarkup.maximumBytes)
    }
    func testStrikethroughSelectionRoundTripKeepsUnicodeAndSurroundings() throws {
        let source = "👩🏽‍💻 Keep Cafe\u{301} 🪴 unchanged."
        let range = (source as NSString).range(of: "Cafe\u{301} 🪴")
        let edit = try NoteFormatting.apply(.strikethrough, to: source, selection: range)
        XCTAssertEqual(edit.text, "👩🏽‍💻 Keep ~~Cafe\u{301} 🪴~~ unchanged.")
        XCTAssertEqual((edit.text as NSString).substring(with: edit.selection), "Cafe\u{301} 🪴")
        XCTAssertEqual(Array(try NoteFormatting.apply(.strikethrough, to: edit.text, selection: edit.selection).text.utf8), Array(source.utf8))
        let marked = (edit.text as NSString).range(of: "~~Cafe\u{301} 🪴~~")
        XCTAssertEqual(Array(try NoteFormatting.apply(.strikethrough, to: edit.text, selection: marked).text.utf8), Array(source.utf8))
    }
    func testStrikethroughPreviewAndPlainTextKeepContentsAndSafeLinks() throws {
        let source = "~~Old draft~~ and [guide](https://example.com/guide)"
        let value = NoteMarkup.inline(source)
        XCTAssertEqual(String(value.characters), "Old draft and guide")
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        XCTAssertEqual(NoteMarkup.plainText(source, includeLinkDestinations: true), "Old draft and guide (https://example.com/guide)")
        let unsafe = "~~Old~~ [blocked](file:///private/test)"
        XCTAssertEqual(String(NoteMarkup.inline(unsafe).characters), unsafe)
    }
    func testStrikethroughAtCaretSelectsPlaceholderAndRejectsBrokenGraphemes() throws {
        let edit = try NoteFormatting.apply(.strikethrough, to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.text, "~~struck text~~"); XCTAssertEqual((edit.text as NSString).substring(with: edit.selection), "struck text")
        for range in [NSRange(location: 1, length: 1), NSRange(location: NSNotFound, length: 0)] {
            XCTAssertThrowsError(try NoteFormatting.apply(.strikethrough, to: "🙂 keep", selection: range))
        }
    }
    func testEveryInlineStyleAcceptsExactBoundaryButRejectsOneExtraByte() throws {
        for style in [NoteFormatting.Style.bold, .italic, .strikethrough, .code, .link] {
            let sample = try NoteFormatting.apply(style, to: "x", selection: NSRange(location: 0, length: 1), url: "https://example.com")
            let growth = sample.text.utf8.count - 1
            let exact = String(repeating: "x", count: NoteMarkup.maximumBytes - growth)
            let edit = try NoteFormatting.apply(style, to: exact, selection: NSRange(location: 0, length: 1), url: "https://example.com")
            XCTAssertEqual(edit.text.utf8.count, NoteMarkup.maximumBytes, style.rawValue)
            XCTAssertNotNil(Range(edit.selection, in: edit.text))
            XCTAssertThrowsError(try NoteFormatting.apply(style, to: exact + "x", selection: NSRange(location: 0, length: 1), url: "https://example.com"), style.rawValue)
        }
    }
    func testRemovingInlineStyleCanShrinkAnExactlyFullNote() throws {
        for (style, marker) in [(NoteFormatting.Style.bold, "**"), (.italic, "_"), (.strikethrough, "~~"), (.code, "`")] {
            let source = marker + "a" + marker + String(repeating: "x", count: NoteMarkup.maximumBytes - marker.utf8.count * 2 - 1)
            let edit = try NoteFormatting.apply(style, to: source, selection: NSRange(location: marker.utf16.count, length: 1))
            XCTAssertEqual(edit.text.utf8.count, NoteMarkup.maximumBytes - marker.utf8.count * 2)
            XCTAssertEqual((edit.text as NSString).substring(with: edit.selection), "a")
        }
    }
    func testFencedCodeAndEscapedLinkExpansionAreBounded() throws {
        let multiline = "line\n" + String(repeating: "x", count: NoteMarkup.maximumBytes - 5)
        XCTAssertThrowsError(try NoteFormatting.apply(.code, to: multiline, selection: NSRange(location: 0, length: multiline.utf16.count)))
        let brackets = String(repeating: "[", count: NoteMarkup.maximumBytes / 2)
        XCTAssertThrowsError(try NoteFormatting.apply(.link, to: brackets, selection: NSRange(location: 0, length: brackets.utf16.count), url: "https://example.com"))
    }

}
