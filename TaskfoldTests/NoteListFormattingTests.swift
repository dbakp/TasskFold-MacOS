import XCTest
@testable import TaskfoldCore

final class NoteListFormattingTests: XCTestCase {
    private func all(_ text: String) -> NSRange { NSRange(location: 0, length: text.utf16.count) }
    func testSwitchBulletsAndNumbersWithoutStackedMarkers() throws {
        let text = "- Review\n  * Résumé 👩🏽‍💻\n+ Ship\n"
        let numbered = try NoteFormatting.apply(.numbered, to: text, selection: all(text))
        XCTAssertEqual(numbered.text, "1. Review\n  2. Résumé 👩🏽‍💻\n3. Ship\n")
        let bullets = try NoteFormatting.apply(.bullet, to: numbered.text, selection: numbered.selection)
        XCTAssertEqual(bullets.text, "- Review\n  - Résumé 👩🏽‍💻\n- Ship\n")
        XCTAssertEqual(try NoteFormatting.apply(.bullet, to: bullets.text, selection: bullets.selection).text, "Review\n  Résumé 👩🏽‍💻\nShip\n")
    }
    func testAllSupportedMarkersToggleToPlainText() throws {
        let bullets = "* One\n+ Two\n- Three\n"
        XCTAssertEqual(try NoteFormatting.apply(.bullet, to: bullets, selection: all(bullets)).text, "One\nTwo\nThree\n")
        let numbers = "9) One\n002. Two\n123456789) Three\n"
        XCTAssertEqual(try NoteFormatting.apply(.numbered, to: numbers, selection: all(numbers)).text, "One\nTwo\nThree\n")
    }
    func testMixedPlainAndListedLinesNormalizeAsOneList() throws {
        let text = "9) One\n\n\t* Two\nThree\n"
        XCTAssertEqual(try NoteFormatting.apply(.numbered, to: text, selection: all(text)).text, "1. One\n\n\t2. Two\n3. Three\n")
        XCTAssertEqual(try NoteFormatting.apply(.bullet, to: text, selection: all(text)).text, "- One\n\n\t- Two\n- Three\n")
    }
    func testPreservesEverySupportedLineEndingAndBlankIndentation() throws {
        for separator in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
            let text = "One" + separator + " \t" + separator + "\tTwo" + separator
            for style in [NoteFormatting.Style.bullet, .numbered, .quote] {
                let edit = try NoteFormatting.apply(style, to: text, selection: all(text))
                let p = style == .bullet ? "- " : style == .numbered ? "1. " : "> "
                let q = style == .numbered ? "2. " : p
                XCTAssertEqual(Array(edit.text.utf8), Array((p + "One" + separator + " \t" + separator + "\t" + q + "Two" + separator).utf8))
                XCTAssertNotNil(Range(edit.selection, in: edit.text))
                XCTAssertEqual(Array(try NoteFormatting.apply(style, to: edit.text, selection: edit.selection).text.utf8), Array(text.utf8))
            }
        }
    }
    func testPartialSelectionPreservesAdjacentExactUnicode() throws {
        let source = "Cafe\u{301}\r\n  4) Re\u{301}sume\u{301} 👩🏽‍💻\r\nUnchanged\u{2028}"
        let edit = try NoteFormatting.apply(.bullet, to: source, selection: (source as NSString).range(of: "sume\u{301}"))
        XCTAssertEqual(Array(edit.text.utf8), Array("Cafe\u{301}\r\n  - Re\u{301}sume\u{301} 👩🏽‍💻\r\nUnchanged\u{2028}".utf8))
        XCTAssertNotNil(Range(edit.selection, in: edit.text))
    }
    func testSelectionEndingAtNextLineDoesNotChangeThatLine() throws {
        let edit = try NoteFormatting.apply(.bullet, to: "First\nSecond\n", selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(edit.text, "- First\nSecond\n")
        XCTAssertEqual(String(edit.text[Range(edit.selection, in: edit.text)!]), "- First")
    }
    func testBlankParagraphSelectsOnlyThePlaceholderAndKeepsEndings() throws {
        for style in [NoteFormatting.Style.bullet, .numbered, .quote] {
            let edit = try NoteFormatting.apply(style, to: "\t\r\n  \r\n", selection: NSRange(location: 0, length: 7))
            XCTAssertEqual(String(edit.text[Range(edit.selection, in: edit.text)!]), style == .quote ? "Quote" : "List item")
            XCTAssertTrue(edit.text.hasSuffix("\r\n  \r\n"))
            XCTAssertTrue(edit.text.hasPrefix("\t"))
        }
    }
    func testQuoteWrapsAndUnwrapsListsWithoutConvertingTheirMarkers() throws {
        let source = "* One\n2) Two\n"
        let quote = try NoteFormatting.apply(.quote, to: source, selection: all(source))
        XCTAssertEqual(quote.text, "> * One\n> 2) Two\n")
        XCTAssertEqual(try NoteFormatting.apply(.quote, to: quote.text, selection: quote.selection).text, source)
    }
    func testLiteralNonMarkersAndOnlyOneStructuralPrefixArePreserved() throws {
        let source = "2026110610. Date\n١. Arabic\n-mail\n*star*\n1. - intentional nesting\n"
        XCTAssertEqual(try NoteFormatting.apply(.bullet, to: source, selection: all(source)).text, "- 2026110610. Date\n- ١. Arabic\n- -mail\n- *star*\n- - intentional nesting\n")
    }
    func testResultBudgetAndInvalidSelectionRefuseInsteadOfChangingText() throws {
        let full = String(repeating: "x", count: NoteMarkup.maximumBytes)
        for style in [NoteFormatting.Style.bullet, .numbered, .quote] {
            XCTAssertThrowsError(try NoteFormatting.apply(style, to: full, selection: all(full)))
            for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 1, length: 1), NSRange(location: 0, length: 100)] {
                XCTAssertThrowsError(try NoteFormatting.apply(style, to: "👩🏽‍💻", selection: range))
            }
        }
    }
    func testPreviewAgreesWithConvertedListBodiesAndMarkers() throws {
        let source = "* **Review**\n+ [Ship](https://example.com)\n"
        let edit = try NoteFormatting.apply(.numbered, to: source, selection: all(source))
        let reading = try NoteMarkup.Prepared(edit.text)
        XCTAssertEqual(reading.document.blocks.filter { if case .numbered = $0.kind { return true }; return false }.map(\.text), ["**Review**", "[Ship](https://example.com)"])
        XCTAssertFalse(reading.document.blocks.contains { $0.text.hasPrefix("* ") || $0.text.hasPrefix("+ ") })
    }
}
