import Foundation

/// Portable note formatting stays in the existing text field. No HTML, embedded
/// resources or executable links are loaded while reading a note.
enum NoteMarkup {
    static let maximumBytes = 512_000
    static let maximumBlocks = 512
    struct Block: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case paragraph, heading(Int), bullet, numbered(String), quote, code(String), divider, space }
        let id: Int
        let kind: Kind
        let text: String
        var depth = 0
    }
    struct Document: Equatable, Sendable {
        let blocks: [Block]
        let formatted: Bool
        let originalOnly: Bool
    }
    static func safeURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }
    private static let destinations = try! NSRegularExpression(pattern: #"\]\(([^)]*)\)"#)
    static func inline(_ raw: String) -> AttributedString {
        guard raw.utf8.count <= maximumBytes, !raw.contains("!["), !(raw.contains("<") && raw.contains(">")), !raw.contains("^[") else { return AttributedString(raw) }
        let links = destinations.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard links.allSatisfy({ match in
            guard let range = Range(match.range(at: 1), in: raw) else { return false }
            return safeURL(String(raw[range])) != nil
        }) else { return AttributedString(raw) }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.allowsExtendedAttributes = false
        guard let value = try? AttributedString(markdown: raw, options: options),
              !value.characters.isEmpty || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.runs.allSatisfy({ $0.link.map { safeURL($0.absoluteString) != nil } ?? true }) else { return AttributedString(raw) }
        return value
    }
    static func document(_ raw: String) -> Document {
        func original() -> Document { Document(blocks: [.init(id: 0, kind: .paragraph, text: raw)], formatted: false, originalOnly: true) }
        guard raw.utf8.count <= maximumBytes else { return original() }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = [], index = 0
        func append(_ kind: Block.Kind, _ text: String, depth: Int = 0) { blocks.append(Block(id: blocks.count, kind: kind, text: text, depth: min(8, depth))) }
        func flush() { if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: "\n")); paragraph = [] } }
        while index < lines.count {
            guard blocks.count < maximumBlocks else { return original() }
            let line = lines[index], leading = line.prefix { $0 == " " || $0 == "\t" }
            let body = String(line.dropFirst(leading.count)), depth = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            index += 1
            if body.isEmpty { flush(); append(.space, ""); continue }
            let ticks = body.prefix { $0 == "`" }, waves = body.prefix { $0 == "~" }
            let fence = ticks.count >= 3 ? String(ticks) : waves.count >= 3 ? String(waves) : ""
            if !fence.isEmpty {
                flush(); var code: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if candidate.hasPrefix(fence), candidate.allSatisfy({ $0 == fence.first! }) { break }
                    code.append(lines[index - 1])
                }
                append(.code(String(body.dropFirst(fence.count).prefix(40))), code.joined(separator: "\n")); continue
            }
            let hashes = body.prefix { $0 == "#" }
            if (1...6).contains(hashes.count), body.dropFirst(hashes.count).first == " " {
                flush(); append(.heading(hashes.count), String(body.dropFirst(hashes.count + 1))); continue
            }
            let rule = body.filter { !$0.isWhitespace }
            if rule.count >= 3, let first = rule.first, "-*_".contains(first), rule.allSatisfy({ $0 == first }) {
                flush(); append(.divider, ""); continue
            }
            if body.hasPrefix("> ") { flush(); append(.quote, String(body.dropFirst(2)), depth: depth); continue }
            if ["- ", "* ", "+ "].contains(where: body.hasPrefix) { flush(); append(.bullet, String(body.dropFirst(2)), depth: depth); continue }
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            if (1...9).contains(digits.count), [". ", ") "].contains(where: { body.dropFirst(digits.count).hasPrefix($0) }) {
                flush(); append(.numbered(String(digits) + "."), String(body.dropFirst(digits.count + 2)), depth: depth); continue
            }
            paragraph.append(line)
        }
        flush()
        guard blocks.count <= maximumBlocks else { return original() }
        let formatted = blocks.contains { block in
            switch block.kind {
            case .paragraph: return String(inline(block.text).characters) != block.text
            case .space: return false
            default: return true
            }
        }
        return Document(blocks: blocks, formatted: formatted, originalOnly: false)
    }
    static func plainText(_ raw: String, includeLinkDestinations: Bool = false) -> String {
        let doc = document(raw)
        guard doc.formatted else { return raw }
        return doc.blocks.map { block in
            let text: String
            if case .code = block.kind { text = block.text } else { text = readableInline(block.text, includeLinkDestinations: includeLinkDestinations) }
            switch block.kind {
            case .bullet: return String(repeating: "  ", count: block.depth) + "• " + text
            case .numbered(let marker): return String(repeating: "  ", count: block.depth) + marker + " " + text
            case .quote: return "> " + text
            case .divider: return "---"
            default: return text
            }
        }.joined(separator: "\n")
    }
    private static func readableInline(_ raw: String, includeLinkDestinations: Bool) -> String {
        let value = inline(raw)
        guard includeLinkDestinations else { return String(value.characters) }
        var result = "", previous: URL?
        for run in value.runs {
            if run.link != previous {
                if let previous { result += " (" + previous.absoluteString + ")" }
                previous = run.link
            }
            result += String(value[run.range].characters)
        }
        if let previous { result += " (" + previous.absoluteString + ")" }
        return result
    }
    static func excerpt(_ raw: String, characters: Int, bytes: Int) -> (String, Bool) {
        let value = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = "", count = 0, used = 0
        for character in value {
            let chunk = String(character), size = chunk.utf8.count
            guard count < characters, used + size <= bytes else { return (result, true) }
            result += chunk; count += 1; used += size
        }
        return (result, false)
    }
    /// Bound markup work before parsing compact lists/widgets. The canonical note is never changed.
    static func preview(_ raw: String, characters: Int, bytes: Int, includeLinkDestinations: Bool = false) -> (String, Bool) {
        guard characters > 0, bytes > 0 else { return ("", !raw.isEmpty) }
        let source = excerpt(raw, characters: min(characters, 10_000) * 2, bytes: min(bytes, 50_000) * 2)
        let result = excerpt(plainText(source.0, includeLinkDestinations: includeLinkDestinations), characters: characters, bytes: bytes)
        return (result.0, source.1 || result.1)
    }
    static func summary(_ raw: String, includeLinkDestinations: Bool = false) -> String {
        let value = preview(raw.trimmingCharacters(in: .whitespacesAndNewlines), characters: 320, bytes: 1600, includeLinkDestinations: includeLinkDestinations)
        return value.0 + (value.1 ? "…" : "")
    }

}
