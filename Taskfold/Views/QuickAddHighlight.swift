import SwiftUI
import AppKit

/// One recognised token located inside the typed text, with the role colour it is drawn in.
struct QuickAddHighlightSpan: Equatable {
    var range: NSRange
    var color: Color
}

/// Finds where each parsed token sits in the typed text. The parser reports the exact raw text of each token but not
/// its position, so this walks the string: the first occurrence that is a whole word, is not an escaped (`\`) or
/// quoted literal and does not overlap an earlier token wins. Repeated identical words that the parser treated
/// differently can therefore be matched to the wrong occurrence; the stored text is never affected.
enum QuickAddHighlight {
    static func spans(in text: String, tokens: [QuickEntry.Token], color: (QuickEntry.Token) -> Color) -> [QuickAddHighlightSpan] {
        let ns = text as NSString
        var taken: [NSRange] = []
        var result: [QuickAddHighlightSpan] = []
        for token in tokens where !token.text.isEmpty {
            var from = 0
            while from < ns.length {
                let found = ns.range(of: token.text, options: [], range: NSRange(location: from, length: ns.length - from))
                guard found.location != NSNotFound else { break }
                from = found.location + 1
                if taken.contains(where: { NSIntersectionRange($0, found).length > 0 }) { continue }
                if isLiteral(ns, found) { continue }
                taken.append(found)
                result.append(QuickAddHighlightSpan(range: found, color: color(token)))
                break
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private static func isLiteral(_ ns: NSString, _ range: NSRange) -> Bool {
        if range.location > 0, ns.character(at: range.location - 1) == 0x5C { return true } // backslash escape
        var quotes = 0
        for index in 0..<range.location where ns.character(at: index) == 0x22 { quotes += 1 }
        // A token that itself starts a quoted name (#"Big project") begins before its quote, so an odd count is a literal.
        if quotes % 2 == 1 { return true }
        let word = CharacterSet.alphanumerics
        func isWord(_ unit: unichar) -> Bool { UnicodeScalar(unit).map { word.contains($0) } ?? false }
        if range.location > 0, let first = ns.substring(with: range).unicodeScalars.first, word.contains(first), isWord(ns.character(at: range.location - 1)) { return true }
        let end = range.location + range.length
        if end < ns.length, let last = ns.substring(with: range).unicodeScalars.last, word.contains(last), isWord(ns.character(at: end)) { return true }
        return false
    }
}

/// Draws a highlight behind and recolours the glyphs of each span, on top of a native text field that sits underneath
/// with identical font, width and insets. It is a pure mirror: it never takes focus or clicks, is hidden from
/// accessibility, and the field underneath stays the only source of text, selection, IME, undo and spell checking.
struct QuickAddHighlightOverlay: NSViewRepresentable {
    let text: String
    let spans: [QuickAddHighlightSpan]
    /// Horizontal inset between the field's frame and its first glyph. Tuned against the SwiftUI plain text field.
    var leadingInset: CGFloat = 0
    var topInset: CGFloat = 0

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let layout = RoundedBackgroundLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false; view.isSelectable = false; view.drawsBackground = false
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.textContainerInset = NSSize(width: leadingInset, height: topInset)
        let font = NSFont.preferredFont(forTextStyle: .title3)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.clear])
        let length = attributed.length
        for span in spans where NSMaxRange(span.range) <= length {
            let color = NSColor(span.color)
            attributed.addAttributes([.foregroundColor: color, .backgroundColor: color.withAlphaComponent(0.15)], range: span.range)
        }
        view.textStorage?.setAttributedString(attributed)
        view.needsDisplay = true
    }

    /// Soft tint behind each token with the xs corner radius from the design tokens.
    final class RoundedBackgroundLayoutManager: NSLayoutManager {
        override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
            color.setFill()
            for index in 0..<rectCount {
                let rect = rectArray[index].insetBy(dx: -1, dy: 1)
                NSBezierPath(roundedRect: rect, xRadius: DS.Radius.xs, yRadius: DS.Radius.xs).fill()
            }
        }
    }
}
