import Foundation

/// Selection-based edits are pure text transformations; callers decide when to save.
enum NoteFormatting {
    enum Style: String, CaseIterable, Sendable { case bold, italic, code, heading, bullet, numbered, quote, link }
    enum ParagraphStyle: String, CaseIterable, Sendable {
        case body, heading1, heading2, heading3
        var title: String { switch self { case .body: "Body"; case .heading1: "Heading 1"; case .heading2: "Heading 2"; case .heading3: "Heading 3" } }
        var level: Int? { switch self { case .body: nil; case .heading1: 1; case .heading2: 2; case .heading3: 3 } }
    }
    struct Edit: Equatable, Sendable { let text: String; let selection: NSRange }
    static func apply(_ style: Style, to text: String, selection: NSRange, url: String = "") throws -> Edit {
        let range = try checkedRange(in: text, selection: selection)
        let chosen = String(text[range]), before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        func wrapping(_ marker: String, placeholder: String) -> Edit {
            if before.hasSuffix(marker), after.hasPrefix(marker) {
                let prefix = String(before.dropLast(marker.count))
                return Edit(text: prefix + chosen + after.dropFirst(marker.count), selection: NSRange(location: prefix.utf16.count, length: chosen.utf16.count))
            }
            if chosen.hasPrefix(marker), chosen.hasSuffix(marker), chosen.count > marker.count * 2 {
                let inner = String(chosen.dropFirst(marker.count).dropLast(marker.count))
                return Edit(text: before + inner + after, selection: NSRange(location: before.utf16.count, length: inner.utf16.count))
            }
            let inner = chosen.isEmpty ? placeholder : chosen
            return Edit(text: before + marker + inner + marker + after, selection: NSRange(location: before.utf16.count + marker.utf16.count, length: inner.utf16.count))
        }
        switch style {
        case .bold: return wrapping("**", placeholder: "bold text")
        case .italic: return wrapping("_", placeholder: "italic text")
        case .code:
            let longest = chosen.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            if !chosen.contains("\n") {
                let marker = String(repeating: "`", count: max(1, longest + 1))
                if before.hasSuffix(marker + " "), after.hasPrefix(" " + marker) {
                    let prefix = String(before.dropLast(marker.count + 1))
                    return Edit(text: prefix + chosen + after.dropFirst(marker.count + 1), selection: NSRange(location: prefix.utf16.count, length: chosen.utf16.count))
                }
                if chosen.hasPrefix("`") || chosen.hasSuffix("`") {
                    return Edit(text: before + marker + " " + chosen + " " + marker + after, selection: NSRange(location: before.utf16.count + marker.count + 1, length: chosen.utf16.count))
                }
                return wrapping(marker, placeholder: "code")
            }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let prefix = before + (before.isEmpty || before.hasSuffix("\n") ? "" : "\n") + fence + "\n"
            return Edit(text: prefix + chosen + (chosen.hasSuffix("\n") ? "" : "\n") + fence + (after.isEmpty || after.hasPrefix("\n") ? "" : "\n") + after, selection: NSRange(location: prefix.utf16.count, length: chosen.utf16.count))
        case .link:
            guard let destination = NoteMarkup.safeURL(url.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AppFailure(message: "Use a web address starting with https:// or http://, without sign-in details.") }
            let label = (chosen.isEmpty ? "link text" : chosen).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let target = destination.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "\\", with: "%5C")
            return Edit(text: before + "[" + label + "](" + target + ")" + after, selection: NSRange(location: before.utf16.count + 1, length: label.utf16.count))
        case .heading: return try paragraph(.heading2, to: text, selection: selection, toggle: true)
        case .bullet, .numbered, .quote:
            return try lineStyle(style, to: text, selection: selection)
        }
    }

    /// List styles replace a supported existing list marker; quote keeps its contents literal.
    /// Keep source line terminators separate so pasted notes round-trip without normalization.
    private static func lineStyle(_ style: Style, to text: String, selection: NSRange) throws -> Edit {
        let span = (text as NSString).lineRange(for: selection)
        guard let range = Range(span, in: text) else { throw AppFailure(message: "Select the lines again before formatting them.") }
        var rows = lines(String(text[range]))
        func parts(_ row: String) -> (indent: String, body: String, marker: Style?) {
            let indent = String(row.prefix { $0 == " " || $0 == "\t" }), body = String(row.dropFirst(indent.count))
            if style == .quote {
                return body.hasPrefix("> ") ? (indent, String(body.dropFirst(2)), .quote) : (indent, body, nil)
            }
            if ["- ", "* ", "+ "].contains(where: body.hasPrefix) { return (indent, String(body.dropFirst(2)), .bullet) }
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            if (1...9).contains(digits.count), [". ", ") "].contains(where: { body.dropFirst(digits.count).hasPrefix($0) }) {
                return (indent, String(body.dropFirst(digits.count + 2)), .numbered)
            }
            return (indent, body, nil)
        }
        let active = rows.indices.filter { !rows[$0].body.trimmingCharacters(in: .whitespaces).isEmpty }
        if active.isEmpty {
            let placeholder = style == .quote ? "Quote" : "List item"
            let prefix = style == .quote ? "> " : style == .bullet ? "- " : "1. "
            let indent = parts(rows[0].body).indent
            rows[0].body = indent + prefix + placeholder
            let replacement = rows.map { $0.body + $0.ending }.joined()
            return try checkedEdit(text: String(text[..<range.lowerBound]) + replacement + text[range.upperBound...], selection: NSRange(location: span.location + indent.utf16.count + prefix.utf16.count, length: placeholder.utf16.count))
        }
        let remove = active.allSatisfy { parts(rows[$0].body).marker == style }
        for (offset, index) in active.enumerated() {
            let row = parts(rows[index].body)
            let prefix = remove ? "" : style == .bullet ? "- " : style == .quote ? "> " : "\(offset + 1). "
            rows[index].body = row.indent + prefix + row.body
        }
        let replacement = rows.map { $0.body + $0.ending }.joined()
        return try checkedEdit(text: String(text[..<range.lowerBound]) + replacement + text[range.upperBound...], selection: NSRange(location: span.location, length: replacement.utf16.count - (rows.last?.ending.utf16.count ?? 0)))
    }
    private static func lines(_ text: String) -> [(body: String, ending: String)] {
        var result: [(body: String, ending: String)] = [], start = text.startIndex
        let endings: Set<Character> = ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]
        for index in text.indices where endings.contains(text[index]) {
            result.append((String(text[start..<index]), String(text[index])))
            start = text.index(after: index)
        }
        if start != text.endIndex || result.isEmpty { result.append((String(text[start...]), "")) }
        return result
    }

    /// Set a paragraph style instead of stacking Markdown heading prefixes.
    /// Only the selected lines change; line endings, indentation and all other bytes stay intact.
    static func paragraph(_ style: ParagraphStyle, to text: String, selection: NSRange) throws -> Edit {
        try paragraph(style, to: text, selection: selection, toggle: false)
    }
    private static func paragraph(_ style: ParagraphStyle, to text: String, selection: NSRange, toggle: Bool) throws -> Edit {
        _ = try checkedRange(in: text, selection: selection)
        let span = (text as NSString).lineRange(for: selection)
        guard let range = Range(span, in: text) else { throw AppFailure(message: "Select the lines again before formatting them.") }
        let original = String(text[range])
        var rows = lines(original)
        func parts(_ row: String) -> (indent: String, body: String, level: Int?) {
            let indent = String(row.prefix { $0 == " " || $0 == "\t" }), body = String(row.dropFirst(indent.count))
            let hashes = body.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count), body.dropFirst(hashes.count).first == " " else { return (indent, body, nil) }
            return (indent, String(body.dropFirst(hashes.count + 1)), hashes.count)
        }
        let nonempty = rows.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let target = toggle && !nonempty.isEmpty && nonempty.allSatisfy({ parts($0.body).level == style.level }) ? nil : style.level
        let prefix = target.map { String(repeating: "#", count: $0) + " " } ?? ""
        if nonempty.isEmpty, target != nil {
            let indent = parts(rows[0].body).indent
            rows[0].body = indent + prefix + "Heading"
            let replacement = rows.map { $0.body + $0.ending }.joined()
            return try checkedEdit(text: String(text[..<range.lowerBound]) + replacement + text[range.upperBound...], selection: NSRange(location: span.location + indent.utf16.count + prefix.utf16.count, length: 7))
        }
        for index in rows.indices {
            guard !rows[index].body.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let value = parts(rows[index].body)
            rows[index].body = value.indent + prefix + value.body
        }
        let replacement = rows.map { $0.body + $0.ending }.joined(), lastEnding = rows.last?.ending.utf16.count ?? 0
        return try checkedEdit(text: String(text[..<range.lowerBound]) + replacement + text[range.upperBound...], selection: NSRange(location: span.location, length: replacement.utf16.count - lastEnding))
    }
    private static func checkedRange(in text: String, selection: NSRange) throws -> Range<String.Index> {
        guard text.utf8.count <= NoteMarkup.maximumBytes else { throw AppFailure(message: "This note is too long for the formatting tools. Its text is unchanged.") }
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location,
              let range = Range(selection, in: text),
              (range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound)),
              (range.upperBound == text.endIndex || text.indices.contains(range.upperBound)) else { throw AppFailure(message: "Select the text again before formatting it.") }
        return range
    }
    private static func checkedEdit(text: String, selection: NSRange) throws -> Edit {
        guard text.utf8.count <= NoteMarkup.maximumBytes else { throw AppFailure(message: "The formatted note would be too long. Its text is unchanged.") }
        return Edit(text: text, selection: selection)
    }
}
