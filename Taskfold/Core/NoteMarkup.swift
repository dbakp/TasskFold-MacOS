import Foundation

/// Portable note formatting stays in the existing text field. No HTML, embedded
/// resources or executable links are loaded while reading a note.
enum NoteMarkup {
    static let maximumBytes = 512_000
    static let maximumBlocks = 512
    /// Source identity is exact UTF-8, including canonically equivalent URL paths.
    struct Source: Equatable, Sendable {
        let text: String
        init(_ text: String) { self.text = text }
        static func == (a: Self, b: Self) -> Bool {
            let shared = a.text.utf8.withContiguousStorageIfAvailable { x in
                b.text.utf8.withContiguousStorageIfAvailable { y in x.count == y.count && x.baseAddress == y.baseAddress } ?? false
            } ?? false
            return shared || a.text.utf8.elementsEqual(b.text.utf8)
        }
    }
    struct Block: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case paragraph, heading(Int), bullet, numbered(String), quote, code(String), divider, space }
        let id: Int
        let kind: Kind
        let text: String
        var depth = 0
        var scrollID: String { NoteMarkup.scrollID(id) }
    }
    static func scrollID(_ id: Int) -> String { "note-content-block-" + String(id) }
    struct Document: Equatable, Sendable {
        let blocks: [Block]
        let formatted: Bool
        let originalOnly: Bool
    }
    /// One source-bound render model per reader. Inline markdown is prepared
    /// outside the interface thread and never recomputed by view redraws.
    struct Heading: Identifiable, Equatable, Sendable { let id: Int; let level: Int; let title: String }
    struct Prepared: Sendable {
        let source: String
        let document: Document
        let headings: [Heading]
        let inlineText: [Int: AttributedString]
        init(_ source: String, checkCancellation: () throws -> Void = {}) throws {
            try checkCancellation()
            let document = NoteMarkup.document(source)
            try checkCancellation()
            var inlineText: [Int: AttributedString] = [:]
            if !document.originalOnly {
                for block in document.blocks {
                    try checkCancellation()
                    switch block.kind {
                    case .code, .divider, .space: break
                    default: inlineText[block.id] = NoteMarkup.inline(block.text)
                    }
                }
            }
            var headings: [Heading] = []
            for block in document.blocks {
                try checkCancellation()
                if case .heading(let level) = block.kind, !document.originalOnly {
                    let title = inlineText[block.id].map { String($0.characters) } ?? block.text
                    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { headings.append(.init(id: block.id, level: level, title: title)) }
                }
            }
            self.headings = headings
            self.source = source; self.document = document; self.inlineText = inlineText
        }
        static func load(_ source: String) async throws -> Self {
            let worker = Task.detached(priority: .userInitiated) {
                try Self(source, checkCancellation: { try Task.checkCancellation() })
            }
            return try await withTaskCancellationHandler(operation: {
                let result = try await worker.value
                try Task.checkCancellation()
                return result
            }, onCancel: { worker.cancel() })
        }
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

/// Reuse display text only. Source/result UTF-8 bytes are bounded in memory;
/// no preview is ever used to save a note or authorize access to its task.
@MainActor final class TaskNotePreviewReadCache {
    struct Context: Equatable {
        let workspace: WorkspaceBinding
        let session: UUID
        let access: UUID
    }
    private struct Key: Hashable { let id: String; let fullText: Bool }
    private struct Entry { let source: String; let result: String; let bytes: Int; var used: UInt64 }
    private var context: Context?
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private let maximumEntries: Int, maximumTextBytes: Int
    private(set) var retainedTextBytes = 0
    private(set) var computationCount = 0
    var count: Int { entries.count }
    init(maximumEntries: Int = 128, maximumTextBytes: Int = 8 * 1024 * 1024) {
        self.maximumEntries = max(0, maximumEntries); self.maximumTextBytes = max(0, maximumTextBytes)
    }
    func clear() { context = nil; entries.removeAll(); retainedTextBytes = 0; clock = 0 }
    private static func sameSource(_ a: String, _ b: String) -> Bool {
        // Both buffers remain borrowed and alive together. No address escapes;
        // independently allocated/canonically equivalent strings still need exact bytes.
        let shared = a.utf8.withContiguousStorageIfAvailable { x in
            b.utf8.withContiguousStorageIfAvailable { y in x.count == y.count && x.baseAddress == y.baseAddress } ?? false
        } ?? false
        return shared || a.utf8.elementsEqual(b.utf8)
    }
    func read(_ source: String, id: String, fullText: Bool, context next: Context) -> String {
        if context != next { clear(); context = next }
        let key = Key(id: id, fullText: fullText); clock &+= 1
        if var entry = entries[key], Self.sameSource(source, entry.source) {
            entry.used = clock; entries[key] = entry; return entry.result
        }
        if let old = entries.removeValue(forKey: key) { retainedTextBytes -= old.bytes }
        guard !source.isEmpty else { return "" }
        computationCount += 1
        let result = fullText ? NoteMarkup.plainText(source, includeLinkDestinations: true).trimmingCharacters(in: .whitespacesAndNewlines)
                              : NoteMarkup.summary(source, includeLinkDestinations: true)
        let bytes = source.utf8.count + result.utf8.count
        if maximumEntries > 0, bytes <= maximumTextBytes {
            while entries.count >= maximumEntries || retainedTextBytes + bytes > maximumTextBytes {
                guard let key = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
                if let old = entries.removeValue(forKey: key) { retainedTextBytes -= old.bytes }
            }
            entries[key] = Entry(source: source, result: result, bytes: bytes, used: clock); retainedTextBytes += bytes
        }
        return result
    }
}
