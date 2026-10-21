import XCTest
@testable import TaskfoldCore

final class NoteMarkupTests: XCTestCase {
    func testParagraphsUnicodeAndOriginalTextRemainLossless() {
        let raw = "Résumé 🙂\r\nA second line\r\n\r\nFinal instruction."
        XCTAssertEqual(NoteMarkup.plainText(raw), raw)
        XCTAssertFalse(NoteMarkup.document(raw).formatted)
        XCTAssertTrue(NoteMarkup.document(raw).blocks.contains { $0.text.contains("Résumé 🙂\nA second line") })
    }
    func testHeadingsListsQuotesCodeAndInlineStylesReadClearly() {
        let raw = "# Guide\n\n**Bold** and _italic_\n- First\n  - Nested\n2. Second\n> Quote\n\n```swift\nlet value = \"**literal**\"\n```"
        let value = NoteMarkup.document(raw)
        XCTAssertTrue(value.formatted); XCTAssertFalse(value.originalOnly)
        XCTAssertEqual(value.blocks.first?.kind, .heading(1))
        XCTAssertTrue(value.blocks.contains { $0.kind == .bullet && $0.depth == 1 && $0.text == "Nested" })
        XCTAssertTrue(value.blocks.contains { $0.kind == .code("swift") && $0.text == "let value = \"**literal**\"" })
        let readable = NoteMarkup.plainText(raw)
        XCTAssertTrue(readable.contains("Bold and italic")); XCTAssertTrue(readable.contains("  • Nested"))
        XCTAssertTrue(readable.contains("2. Second")); XCTAssertTrue(readable.contains("**literal**"))
    }
    func testOnlyWebLinksWithoutCredentialsCanBeOpened() {
        for raw in ["javascript:alert(1)", "file:///private/note", "taskfold://auth", "mailto:a@example.com", "//example.com", "https://user:secret@example.com", "https:///", "https://example.com/\nprivate"] {
            XCTAssertNil(NoteMarkup.safeURL(raw), raw)
            let source = "[Read](\(raw))"
            XCTAssertTrue(NoteMarkup.inline(source).runs.allSatisfy { $0.link == nil }, source)
        }
        let source = "[Read guide](https://example.com/guide?q=one#part)"
        let formatted = NoteMarkup.inline(source)
        XCTAssertEqual(String(formatted.characters), "Read guide")
        XCTAssertEqual(formatted.runs.first?.link?.host, "example.com")
    }
    func testImagesHTMLAndExtendedAttributesStayLiteralWithoutLoadingResources() {
        for source in ["![Private image](https://example.com/image.png)", "<script>doSomething()</script>", "<b>Literal tags</b>", "^[words](foregroundColor: 'red')", "[Bad](javascript:alert%281%29)"] {
            let value = NoteMarkup.inline(source)
            XCTAssertEqual(String(value.characters), source)
            XCTAssertTrue(value.runs.allSatisfy { $0.link == nil })
        }
    }
    func testOversizedAndExcessivelyFragmentedNotesUseCompleteOriginalFallback() {
        for source in [String(repeating: "a", count: NoteMarkup.maximumBytes + 1), Array(repeating: "- item", count: NoteMarkup.maximumBlocks + 1).joined(separator: "\n")] {
            let value = NoteMarkup.document(source)
            XCTAssertTrue(value.originalOnly); XCTAssertEqual(value.blocks.first?.text, source)
            XCTAssertEqual(NoteMarkup.plainText(source), source)
        }
    }
    func testUnclosedCodeFenceAndTabbedListDoNotLoseContent() {
        let source = "~~~text\n**literal**\nlast line"
        let value = NoteMarkup.document(source)
        XCTAssertEqual(value.blocks.first?.text, "**literal**\nlast line")
        XCTAssertEqual(value.blocks.first?.kind, .code("text"))
        XCTAssertEqual(NoteMarkup.document("\t- Child").blocks.first?.depth, 2)
        XCTAssertEqual(String(NoteMarkup.inline("package_name_here").characters), "package_name_here")
    }
}

final class NoteFormattingTests: XCTestCase {
    func testUnicodeSelectionAndRepeatedBoldToggleKeepSurroundingText() throws {
        let raw = "👩🏽‍💻 Review résumé tomorrow"
        let span = (raw as NSString).range(of: "résumé")
        let result = try NoteFormatting.apply(.bold, to: raw, selection: span)
        XCTAssertEqual(result.text, "👩🏽‍💻 Review **résumé** tomorrow")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "résumé")
        XCTAssertEqual(try NoteFormatting.apply(.bold, to: result.text, selection: result.selection).text, raw)
    }
    func testInvalidAndStaleUTF16SelectionsAreRejectedWithoutChangingText() {
        for span in [NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 0), NSRange(location: 2, length: 99), NSRange(location: 1, length: 1)] {
            XCTAssertThrowsError(try NoteFormatting.apply(.bold, to: "🙂 word", selection: span), "Invalid selection: \(span)")
        }
    }
    func testEmptyEditorOffersSelectedPlaceholders() throws {
        for style in NoteFormatting.Style.allCases where style != .link {
            let result = try NoteFormatting.apply(style, to: "", selection: NSRange(location: 0, length: 0))
            XCTAssertFalse(result.text.isEmpty, style.rawValue)
            XCTAssertGreaterThan(result.selection.length, 0)
            XCTAssertNotNil(Range(result.selection, in: result.text))
        }
    }
    func testLineFormattingPreservesBlankLinesIndentationAndFinalNewline() throws {
        let raw = "first\n\n  second\n"
        let result = try NoteFormatting.apply(.bullet, to: raw, selection: NSRange(location: 0, length: raw.utf16.count))
        XCTAssertEqual(result.text, "- first\n\n  - second\n")
        XCTAssertEqual(try NoteFormatting.apply(.bullet, to: result.text, selection: result.selection).text, raw)
        let numbered = try NoteFormatting.apply(.numbered, to: raw, selection: NSRange(location: 0, length: raw.utf16.count))
        XCTAssertEqual(numbered.text, "1. first\n\n  2. second\n")
        XCTAssertEqual(try NoteFormatting.apply(.numbered, to: numbered.text, selection: numbered.selection).text, raw)
    }
    func testWindowsLineEndingsRemainSelectable() throws {
        let raw = "first\r\nsecond\r\n"
        let result = try NoteFormatting.apply(.quote, to: raw, selection: NSRange(location: 0, length: raw.utf16.count))
        XCTAssertEqual(result.text, "> first\r\n> second\r\n")
        XCTAssertNotNil(Range(result.selection, in: result.text))
    }
    func testCodeEscapesItsOwnDelimitersAndPreservesMultilineContent() throws {
        for raw in ["code", "a`b", "`quoted`"] {
            let result = try NoteFormatting.apply(.code, to: raw, selection: NSRange(location: 0, length: raw.utf16.count))
            XCTAssertEqual(String(NoteMarkup.inline(result.text).characters), raw)
            XCTAssertEqual(try NoteFormatting.apply(.code, to: result.text, selection: result.selection).text, raw)
        }
        let raw = "first\n```\n**literal**"
        let result = try NoteFormatting.apply(.code, to: raw, selection: NSRange(location: 0, length: raw.utf16.count))
        XCTAssertTrue(result.text.hasPrefix("````\n"))
        XCTAssertEqual(NoteMarkup.document(result.text).blocks.first?.text, raw)
    }
    func testLinkCreationEscapesBracketsAndURLParentheses() throws {
        let raw = "Review [draft]"
        let result = try NoteFormatting.apply(.link, to: raw, selection: NSRange(location: 0, length: raw.utf16.count), url: "https://example.com/a(b)?q=one")
        let value = NoteMarkup.inline(result.text)
        XCTAssertEqual(String(value.characters), raw)
        XCTAssertEqual(value.runs.first?.link?.absoluteString, "https://example.com/a%28b%29?q=one")
        XCTAssertThrowsError(try NoteFormatting.apply(.link, to: raw, selection: NSRange(location: 0, length: 0), url: "file:///private/note"))
        XCTAssertThrowsError(try NoteFormatting.apply(.link, to: raw, selection: NSRange(location: 0, length: 0), url: "https://user:secret@example.com"))
    }
    func testSelectingOnlyMarkersNeverDeletesThem() throws {
        let result = try NoteFormatting.apply(.bold, to: "****", selection: NSRange(location: 0, length: 4))
        XCTAssertTrue(result.text.contains("****")); XCTAssertGreaterThanOrEqual(result.text.count, 4)
    }
    func testLargeSourceIsRefusedByToolsWithoutTruncatingIt() {
        let raw = String(repeating: "a", count: NoteMarkup.maximumBytes + 1)
        XCTAssertThrowsError(try NoteFormatting.apply(.bold, to: raw, selection: NSRange(location: 0, length: 1)))
        XCTAssertEqual(raw.count, NoteMarkup.maximumBytes + 1)
    }
}

final class FormattedNoteWidgetTests: XCTestCase {
    func testWidgetExcerptIsReadableWhileCanonicalNoteRemainsUnchanged() throws {
        let source = "## Review\n\n**Check contrast**\n- Verify keyboard focus\n[Guide](https://example.com/guide)"
        let task = Record(["id": .string("note-task"), "user_id": .string("owner"), "title": .string("Design guide"), "description": .string(source)])
        let pin = Record(["id": .string(PinnedNotes.key(task.id)), "user_id": .string("owner"), "ids": .array([.string(task.id)])])
        let value = try XCTUnwrap(PinnedNotes.payload(tasks: [task], pins: [pin], account: "owner").first?.object)
        XCTAssertEqual(value["text"]?.text, "Review\n\nCheck contrast\n• Verify keyboard focus\nGuide")
        XCTAssertEqual(task.string("description"), source)
        XCTAssertEqual(value["truncated"], .bool(false))
        XCTAssertTrue(PinnedNotes.payload(tasks: [task], pins: [pin], account: "other").isEmpty)
    }
}

final class CompactNotePreviewTests: XCTestCase {
    func testSummariesKeepUsefulLinkDestinationsWithoutFormattingMarkers() {
        let source = "## Guide\nRead [the **full** guide](https://example.com/guide) today."
        XCTAssertEqual(NoteMarkup.summary(source, includeLinkDestinations: true), "Guide\nRead the full guide (https://example.com/guide) today.")
        XCTAssertEqual(NoteMarkup.summary(source), "Guide\nRead the full guide today.")
    }
    func testCompactWorkIsBoundedAndTruncationRemainsExplicit() {
        let raw = String(repeating: "Résumé 👩🏽‍💻 ", count: 100_000)
        let value = NoteMarkup.preview(raw, characters: 1200, bytes: 6000)
        XCTAssertLessThanOrEqual(value.0.count, 1200); XCTAssertLessThanOrEqual(value.0.utf8.count, 6000)
        XCTAssertTrue(value.1); XCTAssertFalse(value.0.contains("�"))
        XCTAssertTrue(NoteMarkup.summary(raw).hasSuffix("…"))
        XCTAssertEqual(NoteMarkup.preview(raw, characters: 0, bytes: 6000).0, "")
    }
}
