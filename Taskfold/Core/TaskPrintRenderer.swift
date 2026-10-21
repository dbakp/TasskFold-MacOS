import Foundation
import CoreText
import CoreGraphics

/// Vector text, native font fallback and explicit pagination; no web renderer or resources.
enum TaskPrintRenderer {
    enum Paper: String, CaseIterable, Sendable { case a4 = "A4", letter = "US Letter"
        var size: CGSize { self == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792) }
    }
    struct Options: Equatable, Sendable { var paper: Paper = .a4; var notes = true; var checklists = true }
    struct Output: Sendable { let data: Data; let pages: Int }
    private struct Part { let block: Int; let range: CFRange; let top: CGFloat; let height: CGFloat }
    private struct Block { let text: NSAttributedString; let inset: CGFloat; let following: CGFloat }
    private static let ink = CGColor(gray: 0.12, alpha: 1)
    private static let secondary = CGColor(gray: 0.40, alpha: 1)
    private static let accent = CGColor(red: 0.78, green: 0.06, blue: 0.24, alpha: 1)
    private static func attributes(size: CGFloat = 11.5, bold: Bool = false, italic: Bool = false, code: Bool = false, color: CGColor = ink, spacing: CGFloat = 5) -> [NSAttributedString.Key: Any] {
        let system = CTFontCreateUIFontForLanguage(code ? .userFixedPitch : .system, size, nil)!
        // Geeza Pro keeps Arabic glyph-to-Unicode mapping stable in exported PDFs.
        // Retain the system cascade for all other scripts and symbols.
        let cascade = CTFontCopyDefaultCascadeListForLanguages(system, nil) as? [CTFontDescriptor] ?? []
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute as String: [CTFontDescriptorCreateWithNameAndSize("GeezaPro" as CFString, size)] + cascade] as CFDictionary)
        let base = CTFontCreateCopyWithAttributes(system, size, nil, descriptor)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }; if italic { traits.insert(.traitItalic) }
        let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
        var line: CGFloat = 2.5, paragraph = spacing
        let style = withUnsafePointer(to: &line) { l in withUnsafePointer(to: &paragraph) { p in
            var settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: l), CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: p)]
            return CTParagraphStyleCreate(&settings, settings.count)
        } }
        return [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color, NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style]
    }
    private static func text(_ value: String, size: CGFloat = 11.5, bold: Bool = false, color: CGColor = ink) -> NSAttributedString {
        NSAttributedString(string: value + "\n", attributes: attributes(size: size, bold: bold, color: color))
    }
    private static func inline(_ value: String, size: CGFloat = 11.5, bold: Bool = false) -> NSAttributedString {
        let parsed = NoteMarkup.inline(value), result = NSMutableAttributedString(string: "")
        var previous: URL?
        func destination() { if let previous { result.append(NSAttributedString(string: " (" + previous.absoluteString + ")", attributes: attributes(size: size, color: secondary))) } }
        for run in parsed.runs {
            if previous != run.link { destination(); previous = run.link }
            let intent = run.inlinePresentationIntent ?? []
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes(size: size, bold: bold || intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized), code: intent.contains(.code))))
        }
        destination(); result.append(NSAttributedString(string: "\n", attributes: attributes(size: size)))
        return result
    }
    private static func noteBlocks(_ raw: String, inset: CGFloat) -> [Block] {
        guard !raw.isEmpty else { return [] }
        let doc = NoteMarkup.document(raw)
        guard !doc.originalOnly else { return [Block(text: text(raw), inset: inset, following: 0)] }
        return doc.blocks.map { block in
            let value: NSAttributedString
            let following: CGFloat
            var offset = inset
            switch block.kind {
            case .heading(let level): value = inline(block.text, size: level <= 2 ? 14 : 12, bold: true); following = 32
            case .bullet: value = inline("• " + block.text); offset += CGFloat(block.depth) * 8; following = 0
            case .numbered(let marker): value = inline(marker + " " + block.text); offset += CGFloat(block.depth) * 8; following = 0
            case .quote: value = inline("> " + block.text); following = 0
            case .code: value = NSAttributedString(string: block.text + "\n", attributes: attributes(size: 10.5, code: true)); following = 0
            case .divider: value = text("________________________", color: secondary); following = 0
            case .space: value = text("", size: 4); following = 0
            case .paragraph: value = inline(block.text); following = 0
            }
            return Block(text: value, inset: offset, following: following)
        }
    }
    static func render(_ document: PrintDocument, options: Options = Options()) throws -> Output {
        try Task.checkCancellation()
        let page = options.paper.size, margin: CGFloat = 44, top: CGFloat = 62, bottom: CGFloat = 48
        let width = page.width - margin * 2, height = page.height - top - bottom
        var blocks = [Block(text: text(document.title, size: 26, bold: true), inset: 0, following: 28), Block(text: text(document.subtitle, size: 10, color: secondary), inset: 0, following: 0)]
        if document.groups.allSatisfy({ $0.items.isEmpty }) { blocks.append(Block(text: text("No matching tasks"), inset: 0, following: 0)) }
        for group in document.groups where !group.items.isEmpty {
            if !group.title.isEmpty { blocks.append(Block(text: text(group.title, size: 14, bold: true, color: accent), inset: 0, following: 40)) }
            for item in group.items where item.depth == 0 || options.checklists {
                let inset = CGFloat(min(6, item.depth)) * 12
                let printedNotes = options.notes || document.noteOnly ? noteBlocks(item.notes, inset: inset + (document.noteOnly ? 0 : 15)) : []
                if !document.noteOnly {
                    blocks.append(Block(text: inline((item.completed ? "☑ " : "☐ ") + item.title, size: 12.5, bold: true), inset: inset, following: item.metadata.isEmpty ? (printedNotes.isEmpty ? 0 : 26) : 20))
                    if !item.metadata.isEmpty { blocks.append(Block(text: text(item.metadata, size: 9.5, color: secondary), inset: inset + 15, following: printedNotes.isEmpty ? 0 : 24)) }
                }
                blocks += printedNotes
                blocks.append(Block(text: text("", size: 4), inset: inset, following: 0))
                guard blocks.count <= 40_000 else { throw AppFailure(message: "This document has too many text blocks. Choose a smaller selection.") }
            }
        }
        let setters = blocks.map { CTFramesetterCreateWithAttributedString($0.text as CFAttributedString) }
        let heights = blocks.enumerated().map { index, block in
            ceil(CTFramesetterSuggestFrameSizeWithConstraints(setters[index], CFRange(location: 0, length: 0), nil, CGSize(width: width - block.inset, height: height), nil).height) + 3
        }
        var pages: [[Part]] = [[]], used: CGFloat = 0, previousKept = false
        func newPage() throws {
            guard pages.count < 500 else { throw AppFailure(message: "This document exceeds 500 pages. Choose a smaller selection.") }
            pages.append([]); used = 0
        }
        for (index, block) in blocks.enumerated() {
            try Task.checkCancellation()
            var offset = 0
            let availableWidth = width - block.inset
            let total = heights[index]
            var needed = min(height, total), next = index
            // Keep adjacent group/task/metadata/note headings with the first body
            // paragraph when that chain fits. Very long paragraphs may split.
            while blocks[next].following > 0, next + 1 < blocks.count, needed < height {
                next += 1; needed = min(height, needed + heights[next])
            }
            if used > 0, !previousKept, needed > height - used { try newPage() }
            while offset < block.text.length {
                try Task.checkCancellation()
                if height - used < 20 { try newPage() }
                let remaining = height - used
                let desired = CTFramesetterSuggestFrameSizeWithConstraints(setters[index], CFRange(location: offset, length: block.text.length - offset), nil, CGSize(width: availableWidth, height: remaining), nil)
                let frameHeight = min(remaining, ceil(desired.height) + 3)
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: availableWidth, height: frameHeight), transform: nil)
                let frame = CTFramesetterCreateFrame(setters[index], CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { if used > 0 { try newPage(); continue }; throw AppFailure(message: "Some text could not be laid out. Your tasks and notes are unchanged.") }
                pages[pages.count - 1].append(Part(block: index, range: visible, top: used, height: frameHeight))
                offset += visible.length; used += frameHeight
                if offset < block.text.length { try newPage() }
            }
            previousKept = block.following > 0
        }
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextTitle as String: document.title, kCGPDFContextCreator as String: "Taskfold"] as CFDictionary) else { throw AppFailure(message: "The PDF could not be created. Please try again.") }
        func line(_ value: String, size: CGFloat, at point: CGPoint, right: Bool = false, limit: CGFloat? = nil) {
            let source = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes(size: size, color: secondary)))
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes(size: size, color: secondary)))
            let drawn = limit.map { CTLineCreateTruncatedLine(source, $0, .end, token) ?? source } ?? source
            context.textPosition = CGPoint(x: right ? point.x - CTLineGetTypographicBounds(drawn, nil, nil, nil) : point.x, y: point.y)
            CGPDFContextBeginTag(context, .span, [CGPDFTagProperty.actualText.rawValue as String: value] as CFDictionary)
            CTLineDraw(drawn, context)
            CGPDFContextEndTag(context)
        }
        for (number, parts) in pages.enumerated() {
            try Task.checkCancellation()
            context.beginPDFPage(nil); context.textMatrix = .identity
            line("TASKFOLD", size: 8, at: CGPoint(x: margin, y: page.height - 32))
            if number > 0 { line(document.title, size: 9, at: CGPoint(x: margin + 78, y: page.height - 32), limit: width - 78) }
            context.setStrokeColor(CGColor(gray: 0.86, alpha: 1)); context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: page.height - 43)); context.addLine(to: CGPoint(x: page.width - margin, y: page.height - 43)); context.strokePath()
            for part in parts {
                let block = blocks[part.block]
                let path = CGPath(rect: CGRect(x: margin + block.inset, y: page.height - top - part.top - part.height, width: width - block.inset, height: part.height), transform: nil)
                let actualText = block.text.attributedSubstring(from: NSRange(location: part.range.location, length: part.range.length)).string
                CGPDFContextBeginTag(context, .paragraph, [CGPDFTagProperty.actualText.rawValue as String: actualText] as CFDictionary)
                CTFrameDraw(CTFramesetterCreateFrame(setters[part.block], part.range, path, nil), context)
                CGPDFContextEndTag(context)
            }
            line("Page \(number + 1) of \(pages.count)", size: 8, at: CGPoint(x: page.width - margin, y: 25), right: true)
            context.endPDFPage()
            guard data.length <= 32_000_000 else { context.closePDF(); throw AppFailure(message: "This PDF is too large. Choose a smaller selection.") }
        }
        context.closePDF()
        return Output(data: data as Data, pages: pages.count)
    }
}
