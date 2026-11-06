import XCTest
@testable import TaskfoldCore

final class NoteParagraphTests: XCTestCase {
    private func all(_ text: String) -> NSRange { NSRange(location: 0, length: text.utf16.count) }
    func testChangeHierarchyWithoutStackingAndReturnToOriginalBody() throws {
        let original = "Résumé 👩🏽‍💻\n  Release notes\n"
        var text = original
        for style in [NoteFormatting.ParagraphStyle.heading1, .heading2, .heading3] {
            let edit = try NoteFormatting.paragraph(style, to: text, selection: all(text))
            XCTAssertEqual(edit.text, String(repeating: "#", count: style.level!) + " Résumé 👩🏽‍💻\n  " + String(repeating: "#", count: style.level!) + " Release notes\n")
            XCTAssertNotNil(Range(edit.selection, in: edit.text))
            XCTAssertEqual(try NoteFormatting.paragraph(style, to: edit.text, selection: edit.selection), edit)
            text = edit.text
        }
        XCTAssertEqual(Array(try NoteFormatting.paragraph(.body, to: text, selection: all(text)).text.utf8), Array(original.utf8))
    }
    func testMixedExistingLevelsAndBodyBecomeOneChosenLevel() throws {
        let original = "# One\n### Three\nBody\n"
        let edit = try NoteFormatting.paragraph(.heading2, to: original, selection: all(original))
        XCTAssertEqual(edit.text, "## One\n## Three\n## Body\n")
        XCTAssertEqual(try NoteFormatting.paragraph(.body, to: edit.text, selection: edit.selection).text, "One\nThree\nBody\n")
        let headings = try NoteMarkup.Prepared(edit.text).headings
        XCTAssertEqual(headings.map(\.level), [2, 2, 2]); XCTAssertEqual(headings.map(\.title), ["One", "Three", "Body"])
    }
    func testPartialSelectionChangesOnlyItsLineAndLeavesAdjacentUTF8Exact() throws {
        let source = "Cafe\u{301}\n  ### Résumé 🙂\nhttps://example.com/Cafe\u{301}\n"
        let edit = try NoteFormatting.paragraph(.heading1, to: source, selection: (source as NSString).range(of: "Résumé"))
        XCTAssertEqual(Array(edit.text.utf8), Array("Cafe\u{301}\n  # Résumé 🙂\nhttps://example.com/Cafe\u{301}\n".utf8))
        let single = try NoteFormatting.paragraph(.heading3, to: "first\nsecond\n", selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(single.text, "### first\nsecond\n")
    }
    func testLineEndingsBlankLinesAndIndentationRoundTripExactly() throws {
        for ending in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
            let source = "first" + ending + "" + ending + "\tsecond" + ending
            let edit = try NoteFormatting.paragraph(.heading3, to: source, selection: all(source))
            XCTAssertEqual(edit.text, "### first" + ending + "" + ending + "\t### second" + ending)
            XCTAssertNotNil(Range(edit.selection, in: edit.text))
            XCTAssertEqual(Array(try NoteFormatting.paragraph(.body, to: edit.text, selection: edit.selection).text.utf8), Array(source.utf8))
        }
    }
    func testNonHeadingHashesAndOtherMarkupStayLiteral() throws {
        for source in ["#tag", "####### literal", "\\# escaped", "**bold**", "- item", "> quote"] {
            XCTAssertEqual(try NoteFormatting.paragraph(.body, to: source, selection: all(source)).text, source)
            let edit = try NoteFormatting.paragraph(.heading1, to: source, selection: all(source))
            XCTAssertEqual(edit.text, "# " + source)
            XCTAssertEqual(try NoteFormatting.paragraph(.body, to: edit.text, selection: edit.selection).text, source)
        }
    }
    func testEmptyHeadingHasSelectedPlaceholderAndBodyDoesNotInventText() throws {
        for style in [NoteFormatting.ParagraphStyle.heading1, .heading2, .heading3] {
            let edit = try NoteFormatting.paragraph(style, to: "", selection: all(""))
            XCTAssertEqual((edit.text as NSString).substring(with: edit.selection), "Heading")
            XCTAssertEqual(edit.text, String(repeating: "#", count: style.level!) + " Heading")
        }
        XCTAssertEqual(try NoteFormatting.paragraph(.body, to: "", selection: all("")), .init(text: "", selection: all("")))
        let source = "first\n", edit = try NoteFormatting.paragraph(.heading2, to: source, selection: NSRange(location: source.utf16.count, length: 0))
        XCTAssertEqual(edit.text, "first\n## Heading")
    }
    func testLegacyHeadingShortcutStillTogglesAndNormalizesExistingLevels() throws {
        let raw = "# One\n### Three\n"
        let edit = try NoteFormatting.apply(.heading, to: raw, selection: all(raw))
        XCTAssertEqual(edit.text, "## One\n## Three\n")
        XCTAssertEqual(try NoteFormatting.apply(.heading, to: edit.text, selection: edit.selection).text, "One\nThree\n")
    }
    func testInvalidSelectionAndOversizedResultAreRefused() throws {
        for selection in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0), NSRange(location: 1, length: 1), NSRange(location: Int.max, length: 1)] {
            XCTAssertThrowsError(try NoteFormatting.paragraph(.heading1, to: "🙂 text", selection: selection))
        }
        let source = String(repeating: "a", count: NoteMarkup.maximumBytes)
        XCTAssertThrowsError(try NoteFormatting.paragraph(.heading1, to: source, selection: all(source)))
        XCTAssertEqual(try NoteFormatting.paragraph(.body, to: source, selection: all(source)).text, source)
    }
}
