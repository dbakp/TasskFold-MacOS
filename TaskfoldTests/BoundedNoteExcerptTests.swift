import XCTest
@testable import TaskfoldCore

final class BoundedNoteExcerptTests: XCTestCase {
    private func oldExcerpt(_ raw: String, characters: Int, bytes: Int) -> (String, Bool) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var kept = "", count = 0
        for character in normalized {
            let next = kept + String(character)
            if count >= characters || next.utf8.count > bytes { return (kept, true) }
            kept = next; count += 1
        }
        return (kept, false)
    }
    private func oldSummary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = oldExcerpt(trimmed, characters: 640, bytes: 3200)
        let result = oldExcerpt(NoteMarkup.plainText(source.0, includeLinkDestinations: true), characters: 320, bytes: 1600)
        return result.0 + (source.1 || result.1 ? "…" : "")
    }
    func testNormalizedNewlinesKeepExactCharacterAndByteBudgets() {
        let samples = ["", "\r\n", "\r\nx", "A\r\nB\rC", "\r\r\n\n", "A\r\r\nB", "\r\rX", "\r\r\r\nX", "\r\r\n\r\r\n", "e\u{301}\r\n👩🏽‍💻\rend", "🇩🇰\r\n👨‍👩‍👧‍👦 suffix", "\r\n\u{301} tail", " \u{301}\rnext"]
        for source in samples {
            for count in [-1, 0, 1, 2, 4, 12, Int.max] { for limit in [-1, 0, 1, 2, 4, 8, 25, 100, Int.max] {
                let expected = oldExcerpt(source, characters: count, bytes: limit)
                let actual = NoteMarkup.excerpt(source, characters: count, bytes: limit)
                XCTAssertTrue(actual.0.utf8.elementsEqual(expected.0.utf8), "\(source.debugDescription), count=\(count), bytes=\(limit)")
                XCTAssertEqual(actual.1, expected.1)
            } }
        }
        let end = NoteMarkup.excerpt("\r\n", characters: 1, bytes: 1)
        XCTAssertEqual(end.0, "\n"); XCTAssertFalse(end.1)
        let slice = "prefix\r\nbody\rnext".dropFirst(6)
        let all = NoteMarkup.excerpt(slice, characters: Int.max, bytes: Int.max)
        XCTAssertTrue(all.0.utf8.elementsEqual(oldExcerpt(String(slice), characters: Int.max, bytes: Int.max).0.utf8)); XCTAssertFalse(all.1)
    }
    func testSummaryKeepsFoundationScalarTrimmingAndMarkdownMeaning() {
        let bodies = ["# Heading\r\n\r\n**Bold** and [Read](https://example.invalid/cafe\u{301})", "- One\r\n- Two\r\n", "```swift\r\nlet value = 1\r\n```", " \u{301}# Not a heading", "# Header \u{301}", "👩🏽‍💻 progress", String(repeating: "word ", count: 130)]
        let edges = ["", "\r\n\t", "\u{2003}\u{202f}", " \u{301}", "\u{85}\u{a0}"]
        for body in bodies { for leading in edges { for trailing in edges {
            let source = leading + body + trailing
            XCTAssertTrue(NoteMarkup.summary(source, includeLinkDestinations: true).utf8.elementsEqual(oldSummary(source).utf8))
        } } }
    }
    func testLongWhitespaceSuffixDoesNotIntroduceAnEllipsis() {
        let body = "# Brief\r\nKeep the instructions", padding = String(repeating: " \r\n\u{2003}", count: 2000)
        for source in [body + padding, padding + body, padding + body + padding, padding] {
            let result = NoteMarkup.summary(source, includeLinkDestinations: true)
            XCTAssertTrue(result.utf8.elementsEqual(oldSummary(source).utf8)); XCTAssertFalse(result.hasSuffix("…"))
        }
    }
    func testOversizedGraphemeRemainsWholeOrExcluded() {
        let source = "e" + String(repeating: "\u{301}", count: 10000) + " after"
        let result = NoteMarkup.excerpt(source, characters: 2, bytes: 10)
        XCTAssertEqual(result.0, ""); XCTAssertTrue(result.1)
    }
    func testColdCompactPreviewDiagnosticWithLongMeaningfulSuffix() {
        let source = "# Workshop\r\nReview **contrast** and [notes](https://example.invalid/brief).\r\n" + String(repeating: "Next workshop instruction with café and 👩🏽‍💻.\r\n", count: 12000) + "END"
        let rounds = 12
        let before = Date(); var old = ""
        for _ in 0..<rounds { old = oldSummary(source) }
        let baseline = Date().timeIntervalSince(before)
        let after = Date(); var current = ""
        for _ in 0..<rounds { current = NoteMarkup.summary(source, includeLinkDestinations: true) }
        let prepared = Date().timeIntervalSince(after)
        XCTAssertTrue(current.utf8.elementsEqual(old.utf8)); XCTAssertTrue(current.hasSuffix("…"))
        print("COLD_COMPACT_NOTE_DIAGNOSTIC source_bytes=\(source.utf8.count) rounds=\(rounds) reference_ms=\(baseline*1000) current_ms=\(prepared*1000)")
    }
}
