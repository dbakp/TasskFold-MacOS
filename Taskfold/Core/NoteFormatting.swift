import Foundation

/// Selection-based edits are pure text transformations; callers decide when to save.
enum NoteFormatting {
    enum Style: String, CaseIterable, Sendable { case bold, italic, code, heading, bullet, numbered, quote, link }
    struct Edit: Equatable, Sendable { let text: String; let selection: NSRange }
    static func apply(_ style: Style, to text: String, selection: NSRange, url: String = "") throws -> Edit {
        guard text.utf8.count <= NoteMarkup.maximumBytes else { throw AppFailure(message: "This note is too long for the formatting tools. Its text is unchanged.") }
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location,
              let range = Range(selection, in: text),
              (range.lowerBound == text.endIndex || text.indices.contains(range.lowerBound)),
              (range.upperBound == text.endIndex || text.indices.contains(range.upperBound)) else { throw AppFailure(message: "Select the text again before formatting it.") }
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
        case .heading, .bullet, .numbered, .quote:
            let linesRange = (text as NSString).lineRange(for: selection)
            guard let lines = Range(linesRange, in: text) else { throw AppFailure(message: "Select the lines again before formatting them.") }
            let original = String(text[lines]); var rows = original.components(separatedBy: "\n")
            let prefix = style == .heading ? "## " : style == .bullet ? "- " : style == .quote ? "> " : "1. "
            func parts(_ row: String) -> (String, String) { let indent = row.prefix { $0 == " " || $0 == "\t" }; return (String(indent), String(row.dropFirst(indent.count))) }
            func numberedBody(_ body: String) -> String? {
                let digits = body.prefix { $0.isASCII && $0.isNumber }
                return !digits.isEmpty && body.dropFirst(digits.count).hasPrefix(". ") ? String(body.dropFirst(digits.count + 2)) : nil
            }
            if rows.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let placeholder = style == .heading ? "Heading" : style == .quote ? "Quote" : "List item"
                let indent = parts(rows[0]).0
                rows[0] = indent + prefix + placeholder + (rows[0].hasSuffix("\r") ? "\r" : "")
                let replacement = rows.joined(separator: "\n")
                return Edit(text: text[..<lines.lowerBound] + replacement + text[lines.upperBound...], selection: NSRange(location: linesRange.location + indent.utf16.count + prefix.utf16.count, length: placeholder.utf16.count))
            }
            let active = rows.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let remove = !active.isEmpty && active.allSatisfy { row in let body = parts(row).1; return style == .numbered ? numberedBody(body) != nil : body.hasPrefix(prefix) }
            var number = 0
            for index in rows.indices {
                let (indent, body) = parts(rows[index])
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if remove { rows[index] = indent + (style == .numbered ? numberedBody(body)! : String(body.dropFirst(prefix.count))) }
                else if style == .numbered { number += 1; rows[index] = indent + "\(number). " + (numberedBody(body) ?? body) }
                else { rows[index] = indent + (body.hasPrefix(prefix) ? body : prefix + body) }
            }
            let replacement = rows.joined(separator: "\n")
            return Edit(text: text[..<lines.lowerBound] + replacement + text[lines.upperBound...], selection: NSRange(location: linesRange.location, length: replacement.utf16.count - (replacement.hasSuffix("\r\n") ? 2 : replacement.hasSuffix("\n") ? 1 : 0)))
        }
    }
}
