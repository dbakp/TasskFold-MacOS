import Foundation

/// Opaque values are created only by a validated syntax scan. They never enter
/// the floating-point/dictionary projection or a tagged on-disk representation.
struct PreservedJSON: Equatable, Sendable {
    enum Kind: Sendable { case number, object }
    let data: Data
    let kind: Kind
    fileprivate init(data: Data, kind: Kind) { self.data = data; self.kind = kind }
    /// Match authored content across JSONB whitespace, key ordering, escaped
    /// strings and exact decimal notation. Raw bytes remain the write/export
    /// representation. Neither keys nor numeric values pass through String-key
    /// dictionaries or Double in this comparison.
    func sameContent(as other: Self) -> Bool {
        guard kind == other.kind else { return false }
        if data == other.data { return true }
        var left = PreservingJSONSyntax(data: data, detectOpaque: false)
        var right = PreservingJSONSyntax(data: other.data, detectOpaque: false)
        guard let a = try? left.identity(depth: 0), let b = try? right.identity(depth: 0) else { return false }
        return a == b
    }
    func validate(maximumDepth: Int, maximumArray: Int = .max, maximumObject: Int = .max, maximumValues: Int = .max) throws -> Int {
        var syntax = PreservingJSONSyntax(data: data, detectOpaque: false)
        syntax.maximumDepth = maximumDepth; syntax.maximumArray = maximumArray; syntax.maximumObject = maximumObject; syntax.maximumValues = maximumValues
        _ = try syntax.scan(); return syntax.valueCount
    }
}
enum PreservedJSONFailure: Error, LocalizedError {
    case syntax, depth, ambiguousMetadata, encoderRequired, placeholder
    var errorDescription: String? {
        switch self {
        case .syntax: return "This JSON content needs review. Its original is unchanged."
        case .depth: return "This content is too deeply nested to read safely. Its original is unchanged."
        case .ambiguousMetadata: return "These metadata keys need an exact-data review. Their original is unchanged."
        case .encoderRequired: return "This content requires Taskfold’s preserving JSON writer."
        case .placeholder: return "This content couldn’t be encoded safely. Its original is unchanged."
        }
    }
}
struct PreservedJSONPath: Hashable { let values: [String] }
struct PreservedJSONSpan { let range: Range<Int>; let kind: PreservedJSON.Kind }
final class PreservedJSONDecodingContext {
    static let key = CodingUserInfoKey(rawValue: "com.taskfold.preserving-json.decode.v1")!
    let data: Data, spans: [PreservedJSONPath: PreservedJSONSpan]
    private let objects: Set<PreservedJSONPath>
    init(data: Data, spans: [PreservedJSONPath: PreservedJSONSpan]) { self.data = data; self.spans = spans; objects = Set(spans.filter { $0.value.kind == .object }.map(\.key)) }
    private func hasOpaqueAncestor(_ path: PreservedJSONPath) -> Bool {
        guard !objects.isEmpty else { return false }
        for length in 0...path.values.count { if objects.contains(.init(values: Array(path.values.prefix(length)))) { return true } }
        return false
    }
    func value(at keys: [any CodingKey]) throws -> PreservedJSON? {
        let path = PreservedJSONPath(values: keys.map(\.stringValue))
        if let span = spans[path] { return .init(data: data.subdata(in: data.index(data.startIndex, offsetBy: span.range.lowerBound)..<data.index(data.startIndex, offsetBy: span.range.upperBound)), kind: span.kind) }
        // A [String: JSON] decoder must never flatten an opaque ancestor object.
        if hasOpaqueAncestor(path) { throw PreservedJSONFailure.ambiguousMetadata }
        return nil
    }
    func requireRecord(at keys: [any CodingKey]) throws {
        let path = PreservedJSONPath(values: keys.map(\.stringValue))
        if hasOpaqueAncestor(path) { throw PreservedJSONFailure.ambiguousMetadata }
    }

}
final class PreservedJSONEncodingContext {
    static let key = CodingUserInfoKey(rawValue: "com.taskfold.preserving-json.encode.v1")!
    private(set) var parts: [String: Data] = [:]
    func register(_ value: PreservedJSON) -> String {
        let token = "taskfold-preserved-json-" + UUID().uuidString.lowercased() + "-" + String(parts.count)
        parts[token] = value.data; return token
    }
}

/// A per-call Foundation encoder preserves all ordinary Codable behavior.
/// Opaque leaves use unique complete JSON string tokens, then validated lexical
/// replacement. Colliding/missing tokens fail closed; raw data is never quoted,
/// rounded, normalized, or persisted as application metadata.
final class TaskfoldJSONEncoder: @unchecked Sendable {
    private struct Options {
        var outputFormatting: Foundation.JSONEncoder.OutputFormatting = []
        var dateEncodingStrategy: Foundation.JSONEncoder.DateEncodingStrategy = .deferredToDate
        var dataEncodingStrategy: Foundation.JSONEncoder.DataEncodingStrategy = .base64
        var nonConformingFloatEncodingStrategy: Foundation.JSONEncoder.NonConformingFloatEncodingStrategy = .throw
        var keyEncodingStrategy: Foundation.JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
        var userInfo: [CodingUserInfoKey: Any] = [:]
    }
    private let lock = NSLock()
    private var options = Options()
    var outputFormatting: Foundation.JSONEncoder.OutputFormatting { get { lock.withLock { options.outputFormatting } } set { lock.withLock { options.outputFormatting = newValue } } }
    var dateEncodingStrategy: Foundation.JSONEncoder.DateEncodingStrategy { get { lock.withLock { options.dateEncodingStrategy } } set { lock.withLock { options.dateEncodingStrategy = newValue } } }
    var dataEncodingStrategy: Foundation.JSONEncoder.DataEncodingStrategy { get { lock.withLock { options.dataEncodingStrategy } } set { lock.withLock { options.dataEncodingStrategy = newValue } } }
    var nonConformingFloatEncodingStrategy: Foundation.JSONEncoder.NonConformingFloatEncodingStrategy { get { lock.withLock { options.nonConformingFloatEncodingStrategy } } set { lock.withLock { options.nonConformingFloatEncodingStrategy = newValue } } }
    var keyEncodingStrategy: Foundation.JSONEncoder.KeyEncodingStrategy { get { lock.withLock { options.keyEncodingStrategy } } set { lock.withLock { options.keyEncodingStrategy = newValue } } }
    var userInfo: [CodingUserInfoKey: Any] { get { lock.withLock { options.userInfo } } set { lock.withLock { options.userInfo = newValue } } }

    func encode<T: Encodable>(_ value: T) throws -> Data { try encode(value, validatingDepth: nil) }
    fileprivate func encodeValidated<T: Encodable>(_ value: T, maximumDepth: Int) throws -> Data {
        try encode(value, validatingDepth: maximumDepth)
    }
    private func encode<T: Encodable>(_ value: T, validatingDepth: Int?) throws -> Data {
        let options = lock.withLock { self.options }
        let encoder = Foundation.JSONEncoder(), context = PreservedJSONEncodingContext()
        encoder.outputFormatting = options.outputFormatting; encoder.dateEncodingStrategy = options.dateEncodingStrategy
        encoder.dataEncodingStrategy = options.dataEncodingStrategy; encoder.nonConformingFloatEncodingStrategy = options.nonConformingFloatEncodingStrategy
        encoder.keyEncodingStrategy = options.keyEncodingStrategy; encoder.userInfo = options.userInfo; encoder.userInfo[PreservedJSONEncodingContext.key] = context
        let encoded = try encoder.encode(value)
        guard !context.parts.isEmpty else {
            if let validatingDepth {
                var syntax = PreservingJSONSyntax(data: encoded, detectOpaque: false); syntax.maximumDepth = validatingDepth; _ = try syntax.scan()
            }
            return encoded
        }
        var syntax = PreservingJSONSyntax(data: encoded, markers: Set(context.parts.keys))
        _ = try syntax.scan()
        guard context.parts.allSatisfy({ syntax.matches[$0.key]?.count == 1 }) else { throw PreservedJSONFailure.placeholder }
        let replacements = context.parts.map { (syntax.matches[$0.key]![0], $0.value) }.sorted { $0.0.lowerBound < $1.0.lowerBound }
        var capacity = encoded.count
        for (range, bytes) in replacements { let next = capacity.addingReportingOverflow(bytes.count-range.count); guard !next.overflow else { throw PreservedJSONFailure.placeholder }; capacity = next.partialValue }
        var result = Data(); result.reserveCapacity(capacity); var end = 0
        for (range, bytes) in replacements { result.append(encoded[end..<range.lowerBound]); result.append(bytes); end = range.upperBound }
        result.append(encoded[end..<encoded.count])
        // A deeply nested opaque leaf can push an otherwise ordinary envelope
        // over the total depth limit. Validate the completed document as well.
        var completed = PreservingJSONSyntax(data: result, detectOpaque: false); completed.maximumDepth = validatingDepth ?? 512; _ = try completed.scan()
        return result
    }
}
final class TaskfoldJSONDecoder: @unchecked Sendable {
    private struct Options {
        var dateDecodingStrategy: Foundation.JSONDecoder.DateDecodingStrategy = .deferredToDate
        var dataDecodingStrategy: Foundation.JSONDecoder.DataDecodingStrategy = .base64
        var nonConformingFloatDecodingStrategy: Foundation.JSONDecoder.NonConformingFloatDecodingStrategy = .throw
        var keyDecodingStrategy: Foundation.JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
        var userInfo: [CodingUserInfoKey: Any] = [:]
    }
    private let lock = NSLock()
    private var options = Options()
    var dateDecodingStrategy: Foundation.JSONDecoder.DateDecodingStrategy { get { lock.withLock { options.dateDecodingStrategy } } set { lock.withLock { options.dateDecodingStrategy = newValue } } }
    var dataDecodingStrategy: Foundation.JSONDecoder.DataDecodingStrategy { get { lock.withLock { options.dataDecodingStrategy } } set { lock.withLock { options.dataDecodingStrategy = newValue } } }
    var nonConformingFloatDecodingStrategy: Foundation.JSONDecoder.NonConformingFloatDecodingStrategy { get { lock.withLock { options.nonConformingFloatDecodingStrategy } } set { lock.withLock { options.nonConformingFloatDecodingStrategy = newValue } } }
    var keyDecodingStrategy: Foundation.JSONDecoder.KeyDecodingStrategy { get { lock.withLock { options.keyDecodingStrategy } } set { lock.withLock { options.keyDecodingStrategy = newValue } } }
    var userInfo: [CodingUserInfoKey: Any] { get { lock.withLock { options.userInfo } } set { lock.withLock { options.userInfo = newValue } } }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let options = lock.withLock { self.options }
        let data = try Self.utf8(data)
        var syntax = PreservingJSONSyntax(data: data); let spans = try syntax.scan()
        if !spans.isEmpty { switch options.keyDecodingStrategy { case .useDefaultKeys: break; default: throw PreservedJSONFailure.ambiguousMetadata } }
        let decoder = Foundation.JSONDecoder()
        decoder.dateDecodingStrategy = options.dateDecodingStrategy; decoder.dataDecodingStrategy = options.dataDecodingStrategy
        decoder.nonConformingFloatDecodingStrategy = options.nonConformingFloatDecodingStrategy; decoder.keyDecodingStrategy = options.keyDecodingStrategy
        decoder.userInfo = options.userInfo; decoder.userInfo.removeValue(forKey: PreservedJSONDecodingContext.key)
        if !spans.isEmpty { decoder.userInfo[PreservedJSONDecodingContext.key] = PreservedJSONDecodingContext(data: data, spans: spans) }
        return try decoder.decode(type, from: data)
    }
    private static func utf8(_ data: Data) throws -> Data {
        let prefix = Array(data.prefix(4)); let encoding: String.Encoding, skip: Int
        if prefix.starts(with: [0xEF,0xBB,0xBF]) { return data.dropFirst(3) }
        if prefix == [0,0,0xFE,0xFF] { encoding = .utf32BigEndian; skip = 4 }
        else if prefix == [0xFF,0xFE,0,0] { encoding = .utf32LittleEndian; skip = 4 }
        else if prefix.starts(with: [0xFE,0xFF]) { encoding = .utf16BigEndian; skip = 2 }
        else if prefix.starts(with: [0xFF,0xFE]) { encoding = .utf16LittleEndian; skip = 2 }
        else if prefix.count == 4, prefix[0] == 0, prefix[1] == 0, prefix[2] == 0 { encoding = .utf32BigEndian; skip = 0 }
        else if prefix.count == 4, prefix[1] == 0, prefix[2] == 0, prefix[3] == 0 { encoding = .utf32LittleEndian; skip = 0 }
        else if prefix.count >= 2, prefix[0] == 0, prefix[1] != 0 { encoding = .utf16BigEndian; skip = 0 }
        else if prefix.count >= 2, prefix[1] == 0, prefix[0] != 0 { encoding = .utf16LittleEndian; skip = 0 }
        else { return data }
        guard let text = String(data: Data(data.dropFirst(skip)), encoding: encoding) else { throw PreservedJSONFailure.syntax }
        return Data(text.utf8)
    }

}

/// Identity comparison uses decoded UTF-8 bytes for strings/keys and exact
/// normalized decimal tokens. Huge unaddressable exponents retain conservative
/// lexical identity. This representation is never written to disk or sent.
private indirect enum PreservedJSONIdentity: Equatable {
    case string(Data), number(String), literal(UInt8)
    case array([PreservedJSONIdentity]), object([Data: PreservedJSONIdentity])
}

/// Syntax-only scanner. Exact UTF-8 duplicate keys are rejected; distinct raw
/// spellings that Swift dictionaries equate are retained as one opaque object.
/// Normal short integers and unescaped ASCII keys take inexpensive fast paths.
private struct PreservingJSONSyntax {
    let bytes: [UInt8], markers: Set<String>, detectOpaque: Bool
    var offset = 0, valueCount = 0
    var maximumDepth = 512, maximumArray = Int.max, maximumObject = Int.max, maximumValues = Int.max
    var matches: [String: [Range<Int>]] = [:]
    init(data: Data, markers: Set<String> = [], detectOpaque: Bool = true) { bytes = Array(data); self.markers = markers; self.detectOpaque = detectOpaque }
    mutating func scan() throws -> [PreservedJSONPath: PreservedJSONSpan] {
        let spans = try value(path: [], depth: 0); space(); guard offset == bytes.count else { throw PreservedJSONFailure.syntax }; return spans
    }
    mutating func space() { while offset < bytes.count && [9,10,13,32].contains(bytes[offset]) { offset += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { space(); guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true }
    mutating func value(path: [String], depth: Int) throws -> [PreservedJSONPath: PreservedJSONSpan] {
        guard depth <= maximumDepth, valueCount < maximumValues else { throw PreservedJSONFailure.depth }; valueCount += 1; space(); let start = offset
        guard offset < bytes.count else { throw PreservedJSONFailure.syntax }
        switch bytes[offset] {
        case 123:
            guard depth < maximumDepth else { throw PreservedJSONFailure.depth }
            offset += 1; var spans: [PreservedJSONPath: PreservedJSONSpan] = [:], rawKeys = Set<Data>(), keys = Set<String>(), collision = false
            if take(125) { return spans }
            repeat {
                space(); let range = try string(); let key = try decodedString(range)
                guard rawKeys.insert(Data(key.utf8)).inserted, rawKeys.count <= maximumObject, take(58) else { throw PreservedJSONFailure.syntax }
                if !keys.insert(key).inserted { collision = true }
                spans.merge(try value(path: path + [key], depth: depth + 1)) { first,_ in first }
                if take(125) { if collision && detectOpaque { return [PreservedJSONPath(values: path): .init(range: start..<offset, kind: .object)] }; return spans }
                guard take(44) else { throw PreservedJSONFailure.syntax }
            } while true
        case 91:
            guard depth < maximumDepth else { throw PreservedJSONFailure.depth }
            offset += 1; var spans: [PreservedJSONPath: PreservedJSONSpan] = [:], index = 0
            if take(93) { return spans }
            repeat {
                guard index < maximumArray else { throw PreservedJSONFailure.depth }
                spans.merge(try value(path: path + ["Index \(index)"], depth: depth + 1)) { first,_ in first }; index += 1
                if take(93) { return spans }; guard take(44) else { throw PreservedJSONFailure.syntax }
            } while true
        case 34:
            let range = try string()
            if !markers.isEmpty, range.count >= 26, bytes[range.lowerBound + 1] == 116 {
                let token = try decodedString(range); if markers.contains(token) { matches[token, default: []].append(range) }
            }
            return [:]
        case 116: try literal(Array("true".utf8)); return [:]
        case 102: try literal(Array("false".utf8)); return [:]
        case 110: try literal(Array("null".utf8)); return [:]
        default:
            let range = try number()
            guard detectOpaque else { return [:] }
            let token = String(decoding: bytes[range], as: UTF8.self)
            if token.utf8.count <= 15, !token.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return [:] }
            if let number = Double(token), number.isFinite, abs(number) <= 9_007_199_254_740_991,
               let encoded = try? Foundation.JSONEncoder().encode(number),
               let before = Self.decimal(token), let after = Self.decimal(String(decoding: encoded, as: UTF8.self)), before == after { return [:] }
            return [PreservedJSONPath(values: path): .init(range: range, kind: .number)]
        }
    }
    mutating func identity(depth: Int) throws -> PreservedJSONIdentity {
        guard depth <= maximumDepth else { throw PreservedJSONFailure.depth }; space()
        guard offset < bytes.count else { throw PreservedJSONFailure.syntax }
        switch bytes[offset] {
        case 123:
            offset += 1; var result: [Data: PreservedJSONIdentity] = [:]
            if take(125) { return .object(result) }
            repeat {
                space(); let range = try string(); let key = Data(try decodedString(range).utf8)
                guard result[key] == nil, take(58) else { throw PreservedJSONFailure.syntax }
                result[key] = try identity(depth: depth + 1)
                if take(125) { return .object(result) }; guard take(44) else { throw PreservedJSONFailure.syntax }
            } while true
        case 91:
            offset += 1; var result: [PreservedJSONIdentity] = []
            if take(93) { return .array(result) }
            repeat {
                result.append(try identity(depth: depth + 1))
                if take(93) { return .array(result) }; guard take(44) else { throw PreservedJSONFailure.syntax }
            } while true
        case 34:
            let range = try string(); return .string(Data(try decodedString(range).utf8))
        case 116: try literal(Array("true".utf8)); return .literal(116)
        case 102: try literal(Array("false".utf8)); return .literal(102)
        case 110: try literal(Array("null".utf8)); return .literal(110)
        default:
            let range = try number(); let token = String(decoding: bytes[range], as: UTF8.self)
            return .number(Self.decimal(token) ?? "raw:" + token)
        }
    }

    mutating func literal(_ value: [UInt8]) throws {
        guard offset + value.count <= bytes.count, Array(bytes[offset..<offset+value.count]) == value else { throw PreservedJSONFailure.syntax }; offset += value.count
    }
    struct ObjectMember { let key: String; let keyRange: Range<Int>; let value: Range<Int> }
    mutating func objectMembers() throws -> [ObjectMember] {
        space(); guard take(123) else { throw PreservedJSONFailure.syntax }
        var members: [ObjectMember] = [], keys = Set<Data>()
        if take(125) { space(); guard offset == bytes.count else { throw PreservedJSONFailure.syntax }; return members }
        repeat {
            space(); let keyRange = try string(), key = try decodedString(keyRange)
            guard keys.insert(Data(key.utf8)).inserted, take(58) else { throw PreservedJSONFailure.syntax }
            space(); let start = offset; _ = try value(path: [], depth: 1)
            members.append(ObjectMember(key: key, keyRange: keyRange, value: start..<offset))
            if take(125) { space(); guard offset == bytes.count else { throw PreservedJSONFailure.syntax }; return members }
            guard take(44) else { throw PreservedJSONFailure.syntax }
        } while true
    }
    mutating func number() throws -> Range<Int> {
        let start = offset
        if offset < bytes.count && bytes[offset] == 45 { offset += 1 }
        guard offset < bytes.count else { throw PreservedJSONFailure.syntax }
        if bytes[offset] == 48 { offset += 1 }
        else { guard (49...57).contains(bytes[offset]) else { throw PreservedJSONFailure.syntax }; repeat { offset += 1 } while offset < bytes.count && (48...57).contains(bytes[offset]) }
        if offset < bytes.count && bytes[offset] == 46 { offset += 1; let digits = offset; while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }; guard offset > digits else { throw PreservedJSONFailure.syntax } }
        if offset < bytes.count && [69,101].contains(bytes[offset]) {
            offset += 1; if offset < bytes.count && [43,45].contains(bytes[offset]) { offset += 1 }; let digits = offset
            while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }; guard offset > digits else { throw PreservedJSONFailure.syntax }
        }
        return start..<offset
    }
    mutating func string() throws -> Range<Int> {
        let start = offset; guard offset < bytes.count && bytes[offset] == 34 else { throw PreservedJSONFailure.syntax }; offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 { return start..<offset }
            if byte == 92 {
                guard offset < bytes.count else { throw PreservedJSONFailure.syntax }; let escaped = bytes[offset]; offset += 1
                if escaped == 117 {
                    let scalar = try hex()
                    if (0xD800...0xDBFF).contains(scalar) { guard offset + 2 <= bytes.count, bytes[offset] == 92, bytes[offset+1] == 117 else { throw PreservedJSONFailure.syntax }; offset += 2; guard (0xDC00...0xDFFF).contains(try hex()) else { throw PreservedJSONFailure.syntax } }
                    else if (0xDC00...0xDFFF).contains(scalar) { throw PreservedJSONFailure.syntax }
                } else { guard [34,47,92,98,102,110,114,116].contains(escaped) else { throw PreservedJSONFailure.syntax } }
            } else if byte < 32 { throw PreservedJSONFailure.syntax }
            else if byte >= 128 {
                let count: Int, first: ClosedRange<UInt8>
                switch byte { case 0xC2...0xDF: count = 1; first = 0x80...0xBF; case 0xE0: count = 2; first = 0xA0...0xBF; case 0xE1...0xEC,0xEE...0xEF: count = 2; first = 0x80...0xBF; case 0xED: count = 2; first = 0x80...0x9F; case 0xF0: count = 3; first = 0x90...0xBF; case 0xF1...0xF3: count = 3; first = 0x80...0xBF; case 0xF4: count = 3; first = 0x80...0x8F; default: throw PreservedJSONFailure.syntax }
                guard offset + count <= bytes.count, first.contains(bytes[offset]) else { throw PreservedJSONFailure.syntax }
                if count > 1 { for index in 1..<count { guard (0x80...0xBF).contains(bytes[offset+index]) else { throw PreservedJSONFailure.syntax } } }; offset += count
            }
        }
        throw PreservedJSONFailure.syntax
    }
    mutating func hex() throws -> UInt16 {
        guard offset + 4 <= bytes.count else { throw PreservedJSONFailure.syntax }; var value: UInt16 = 0
        for _ in 0..<4 { let byte = bytes[offset]; offset += 1; let digit: UInt8
            switch byte { case 48...57: digit = byte - 48; case 65...70: digit = byte - 55; case 97...102: digit = byte - 87; default: throw PreservedJSONFailure.syntax }; value = value * 16 + UInt16(digit) }
        return value
    }
    func decodedString(_ range: Range<Int>) throws -> String {
        if !bytes[range].contains(92) { guard let value = String(bytes: bytes[(range.lowerBound+1)..<(range.upperBound-1)], encoding: .utf8) else { throw PreservedJSONFailure.syntax }; return value }
        return try Foundation.JSONDecoder().decode(String.self, from: Data(bytes[range]))
    }
    static func decimal(_ token: String) -> String? {
        var text = token[...], negative = false
        if text.first == "-" { negative = true; text.removeFirst() }
        let pieces = text.split(whereSeparator: { $0 == "e" || $0 == "E" }); guard pieces.count <= 2 else { return nil }
        guard var exponent = pieces.count == 2 ? Int(pieces[1]) : 0 else { return nil }
        let mantissa = pieces[0].split(separator: ".", omittingEmptySubsequences: false), digits = Array(mantissa.joined().utf8)
        var first = 0, last = digits.count
        while first < last && digits[first] == 48 { first += 1 }
        if first == last { return negative ? "-0" : "0" }
        while last > first && digits[last-1] == 48 { last -= 1 }
        let fraction = mantissa.count == 2 ? mantissa[1].utf8.count : 0; let reduced = exponent.subtractingReportingOverflow(fraction); guard !reduced.overflow else { return nil }; exponent = reduced.partialValue
        let increased = exponent.addingReportingOverflow(digits.count-last); guard !increased.overflow else { return nil }
        return (negative ? "-" : "") + String(decoding: digits[first..<last], as: UTF8.self) + "e" + String(increased.partialValue)
    }
}

// Extensions use the codec without the app task model.
#if !TASKFOLD_SHARE_EXTENSION && !TASKFOLD_WIDGET_EXTENSION
/// A projection is only for field-level editors/patches. It must never replace
/// the source object: Swift cannot represent its distinct canonically-equal keys.
extension JSON {
    func fieldEditingProjection() throws -> [String: JSON] { try asciiProjection(only: nil) }
    /// Read selected display fields without decoding or replacing unrelated values.
    func readingASCIIFields(_ names: Set<String>) throws -> [String: JSON] {
        guard names.allSatisfy(Self.asciiField) else { throw PreservedJSONFailure.ambiguousMetadata }
        return try asciiProjection(only: names)
    }
    private func asciiProjection(only names: Set<String>?) throws -> [String: JSON] {
        switch self {
        case .object(let fields): return fields.filter { $0.key.utf8.allSatisfy { $0 < 128 } && (names?.contains($0.key) ?? true) }
        case .preserved(let source) where source.kind == .object:
            var syntax = PreservingJSONSyntax(data: source.data, detectOpaque: false)
            let members = try syntax.objectMembers()
            var fields: [String: JSON] = [:]
            for member in members where member.key.utf8.allSatisfy({ $0 < 128 }) && (names?.contains(member.key) ?? true) {
                fields[member.key] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(syntax.bytes[member.value]))
            }
            return fields
        default: throw PreservedJSONFailure.ambiguousMetadata
        }
    }
    /// Update only unambiguous ASCII field names. Untouched member tokens,
    /// including distinct Unicode keys, numbers and nested values, stay exact.
    func editingASCIIFields(_ changes: [String: JSON], removing: Set<String> = []) throws -> JSON {
        guard Set(changes.keys).isDisjoint(with: removing), changes.keys.allSatisfy(Self.asciiField), removing.allSatisfy(Self.asciiField) else { throw PreservedJSONFailure.ambiguousMetadata }
        switch self { case .object: break; case .preserved(let source) where source.kind == .object: break; default: throw PreservedJSONFailure.ambiguousMetadata }
        if changes.isEmpty && removing.isEmpty { return self }
        if case .object(var fields) = self, fields.keys.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) {
            for key in removing { fields.removeValue(forKey: key) }
            for (key, value) in changes { fields[key] = value }
            return .object(fields)
        }
        let sourceData: Data
        if case .preserved(let source) = self { sourceData = source.data }
        else { sourceData = try TaskfoldJSONEncoder().encode(self) }
        var syntax = PreservingJSONSyntax(data: sourceData, detectOpaque: false)
        let members = try syntax.objectMembers(), encoder = TaskfoldJSONEncoder()
        var parts: [Data] = [], handled = Set<String>(), changed = false
        for member in members {
            // Non-ASCII names never enter a String-key dictionary lookup.
            let ascii = member.key.utf8.allSatisfy { $0 < 128 }
            if ascii && removing.contains(member.key) { changed = true; continue }
            if ascii, let value = changes[member.key] {
                handled.insert(member.key)
                let original = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(syntax.bytes[member.value]))
                if AuthoredValueComparison.exactJSON(original, value) {
                    parts.append(Data(syntax.bytes[member.keyRange.lowerBound..<member.value.upperBound]))
                } else {
                    var data = Data(syntax.bytes[member.keyRange.lowerBound..<member.value.lowerBound]); data.append(try encoder.encode(value)); parts.append(data); changed = true
                }
            } else { parts.append(Data(syntax.bytes[member.keyRange.lowerBound..<member.value.upperBound])) }
        }
        for key in changes.keys.filter({ !handled.contains($0) }).sorted() {
            var data = try encoder.encode(key); data.append(58); data.append(try encoder.encode(changes[key]!)); parts.append(data); changed = true
        }
        guard changed else { return self }
        var data = Data([123])
        for (offset, part) in parts.enumerated() { if offset > 0 { data.append(44) }; data.append(part) }
        data.append(125)
        return try TaskfoldJSONDecoder().decode(JSON.self, from: data)
    }
    private static func asciiField(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 200 && value.utf8.allSatisfy { $0 < 128 } }
}
#endif

#if !TASKFOLD_SHARE_EXTENSION && !TASKFOLD_WIDGET_EXTENSION
/// Reuses only byte-exact unchanged field values. File shape, current metadata,
/// row order and every current field remain owned by the ordinary Snapshot.
final class SnapshotFieldEncodingCache {
    struct Statistics: Equatable { var reused = 0; var encoded = 0; var retained = 0; var retainedBytes = 0 }
    private struct Key: Hashable { let table: Data, row: Data, field: Data }
    private struct Entry { let value: JSON; let data: Data }
    private enum Unavailable: Error { case header }
    private let maximumBytes: Int, maximumEntries: Int
    private var entries: [Key: Entry] = [:]
    private var previousBodySize = 0
    private(set) var statistics = Statistics()
    init(maximumBytes: Int = 16 * 1024 * 1024, maximumEntries: Int = 50_000) {
        self.maximumBytes = max(0, maximumBytes); self.maximumEntries = max(0, maximumEntries)
    }
    func clear() { entries = [:]; previousBodySize = 0; statistics = Statistics() }
    /// Avoid repeatedly re-encoding the uncached tail of a workspace that cannot
    /// fit this memo. The last complete envelope conservatively charges values;
    /// add every current key and entry overhead before selecting this writer.
    func admits(_ snapshot: Snapshot, knownBytes: Int) -> Bool {
        guard knownBytes >= 0, knownBytes <= maximumBytes else { return false }
        var cost = knownBytes, count = 0
        for (table, rows) in snapshot.tables {
            guard table.utf8.count <= 256 else { return false }
            for row in rows {
                let rowBytes = row.id.utf8.count
                guard rowBytes > 0, rowBytes <= 256 else { return false }
                for field in row.fields.keys {
                    guard field.utf8.count <= 512, count < maximumEntries else { return false }
                    let extra = table.utf8.count + rowBytes + field.utf8.count + 128
                    guard extra <= maximumBytes - cost else { return false }
                    cost += extra; count += 1
                }
            }
        }
        // Optimized measurements show little warm gain and a cold penalty for
        // large plain workspaces. Keep their ordinary encoder; opaque values
        // make whole-envelope syntax scans expensive and justify field reuse.
        return count <= 8192 || snapshot.tables.values.contains { rows in
            rows.contains { row in row.fields.values.contains(where: Self.containsPreserved) }
        }
    }
    private static func containsPreserved(_ value: JSON) -> Bool {
        switch value {
        case .preserved: return true
        case .array, .object: break
        default: return false
        }
        var pending = [value]
        while let item = pending.popLast() {
            switch item {
            case .preserved: return true
            case .array(let values): pending.append(contentsOf: values)
            case .object(let values): pending.append(contentsOf: values.values)
            default: break
            }
        }
        return false
    }
    func encode(_ snapshot: Snapshot) throws -> Data {
        var metadata = snapshot; metadata.tables = [:]
        let encoder = TaskfoldJSONEncoder(), header = try encoder.encode(metadata)
        guard header.count <= 512 * 1024 else { throw Unavailable.header }
        var syntax = PreservingJSONSyntax(data: header, detectOpaque: false)
        let members = try syntax.objectMembers()
        guard let slot = members.first(where: { $0.key == "tables" }), header[slot.value] == Data("{}".utf8) else { throw Unavailable.header }
        // Repeated schema names are identical across thousands of task fields.
        // Keep only a small per-call UTF-8-exact name memo; unknown names still
        // encode normally after this independent budget is exhausted.
        var encodedNames: [Data: Data] = [:], nameBytesRetained = 0
        func nameBytes(_ name: String) throws -> Data {
            let raw = Data(name.utf8)
            if let hit = encodedNames[raw] { return hit }
            let data = try encoder.encode(name)
            let cost = raw.count + data.count + 128
            if encodedNames.count < 512, cost <= 64 * 1024 - nameBytesRetained {
                encodedNames[raw] = data; nameBytesRetained += cost
            }
            return data
        }
        var body = Data([123]); body.reserveCapacity(min(maximumBytes, previousBodySize))
        var next: [Key: Entry] = [:], measured = Statistics()
        next.reserveCapacity(min(maximumEntries, entries.count))
        for (tableIndex, name) in snapshot.tables.keys.sorted().enumerated() {
            if tableIndex > 0 { body.append(44) }
            body.append(try nameBytes(name)); body.append(contentsOf: [58, 91])
            let tableKey = name.utf8.count <= 256 ? Data(name.utf8) : nil
            for (rowIndex, row) in snapshot.tables[name]!.enumerated() {
                if rowIndex > 0 { body.append(44) }; body.append(123)
                let rowKey = !row.id.isEmpty && row.id.utf8.count <= 256 ? Data(row.id.utf8) : nil
                for (fieldIndex, field) in row.fields.keys.sorted().enumerated() {
                    if fieldIndex > 0 { body.append(44) }
                    body.append(try nameBytes(field)); body.append(58)
                    let value = row.fields[field]!
                    let key: Key? = if let tableKey, let rowKey, field.utf8.count <= 512 {
                        Key(table: tableKey, row: rowKey, field: Data(field.utf8))
                    } else { nil }
                    let entry: Entry
                    if let key, let cached = next[key] ?? entries[key], Self.exact(cached.value, value) {
                        entry = cached; measured.reused += 1
                    } else {
                        // tables → named array → record → field: four levels
                        // surround this independently validated JSON value.
                        entry = Entry(value: value, data: try encoder.encodeValidated(value, maximumDepth: 508)); measured.encoded += 1
                    }
                    body.append(entry.data)
                    if let key, next[key] == nil, next.count < maximumEntries {
                        let cost = key.table.count + key.row.count + key.field.count + entry.data.count + 128
                        if cost <= maximumBytes - measured.retainedBytes { next[key] = entry; measured.retainedBytes += cost }
                    }
                }
                body.append(125)
            }
            body.append(93)
        }
        body.append(125)
        let count = (header.count - slot.value.count).addingReportingOverflow(body.count)
        guard !count.overflow else { throw Unavailable.header }
        var result = Data(); result.reserveCapacity(count.partialValue)
        result.append(header[..<slot.value.lowerBound]); result.append(body); result.append(header[slot.value.upperBound...])
        entries = next; previousBodySize = body.count; measured.retained = next.count; statistics = measured
        return result
    }
    /// Semantic String/Double/opaque-object equality is insufficient for saved
    /// bytes. Equal COW arrays/strings may avoid walking a large untouched value.
    private static func exact(_ lhs: JSON, _ rhs: JSON) -> Bool {
        var pending = [(lhs, rhs)]
        while let (a, b) = pending.popLast() {
            switch (a, b) {
            case (.null, .null): break
            case (.bool(let x), .bool(let y)): if x != y { return false }
            case (.number(let x), .number(let y)): if x.bitPattern != y.bitPattern { return false }
            case (.string(let x), .string(let y)): if !sameString(x, y) { return false }
            case (.preserved(let x), .preserved(let y)): if x.kind != y.kind || x.data != y.data { return false }
            case (.array(let x), .array(let y)):
                guard x.count == y.count else { return false }
                let shared = x.withUnsafeBufferPointer { a in y.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
                if !shared { pending.append(contentsOf: zip(x, y)) }
            case (.object(let x), .object(let y)):
                guard x.count == y.count else { return false }
                for (key, value) in x {
                    guard let index = y.index(forKey: key), sameString(key, y[index].key) else { return false }
                    pending.append((value, y[index].value))
                }
            default: return false
            }
        }
        return true
    }
    private static func sameString(_ lhs: String, _ rhs: String) -> Bool {
        var a = lhs, b = rhs
        return a.withUTF8 { x in b.withUTF8 { y in x.count == y.count && (x.baseAddress == y.baseAddress || x.elementsEqual(y)) } }
    }
}
#endif
