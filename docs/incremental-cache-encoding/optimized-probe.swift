import Foundation

/// Exact authored-source comparison for caches and reviewed output. Domain-level
/// Record/JSON equality keeps its existing semantic behavior.
enum AuthoredValueComparison {
    static func sameRows(_ lhs: [Record], _ rhs: [Record]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let identical = lhs.withUnsafeBufferPointer { a in rhs.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        if identical { return true }
        return zip(lhs, rhs).allSatisfy { exactJSON(.object($0.fields), .object($1.fields)) }
    }
    /// Iterative traversal avoids adding recursive stack depth for opaque fields
    /// in a pinned note. Object ordering is irrelevant; key/value bytes are exact.
    static func exactJSON(_ lhs: JSON, _ rhs: JSON) -> Bool {
        var pending = [(lhs, rhs)]
        while let (a, b) = pending.popLast() {
            switch (a, b) {
            case (.null, .null): break
            case (.preserved(let x), .preserved(let y)): if !x.sameContent(as: y) { return false }
            case (.bool(let x), .bool(let y)): if x != y { return false }
            case (.number(let x), .number(let y)): if x.bitPattern != y.bitPattern { return false }
            case (.string(let x), .string(let y)): if !x.utf8.elementsEqual(y.utf8) { return false }
            case (.array(let x), .array(let y)):
                guard x.count == y.count else { return false }
                // Immutable value copies can keep the same backing buffer. A changed
                // array detaches before writing, so only different buffers need a walk.
                let identical = x.withUnsafeBufferPointer { a in y.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
                if !identical { pending.append(contentsOf: zip(x, y)) }
            case (.object(let x), .object(let y)):
                guard x.count == y.count else { return false }
                for (key, value) in x {
                    guard let index = y.index(forKey: key), key.utf8.elementsEqual(y[index].key.utf8) else { return false }
                    pending.append((value, y[index].value))
                }
            default: return false
            }
        }
        return true
    }
}

/// Familiar values stay editable; unrepresentable future values retain exact
/// validated bytes through Taskfold’s preserving codec.
enum JSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null, preserved(PreservedJSON)
    init(from decoder: Decoder) throws {
        if let context = decoder.userInfo[PreservedJSONDecodingContext.key] as? PreservedJSONDecodingContext, let value = try context.value(at: decoder.codingPath) { self = .preserved(value); return }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .preserved(let value):
            guard let context = encoder.userInfo[PreservedJSONEncodingContext.key] as? PreservedJSONEncodingContext else { throw PreservedJSONFailure.encoderRequired }
            try c.encode(context.register(value))
        }
    }
    var text: String { if case .string(let v) = self { return v }; return "" }
    var flag: Bool { if case .bool(let v) = self { return v }; return false }
    var integer: Int { if case .number(let v) = self, v.isFinite, let value = Int(exactly: v.rounded(.towardZero)) { return value }; return 0 }
    var list: [JSON] { if case .array(let v) = self { return v }; return [] }
    var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
}

struct Record: Codable { var fields: [String: JSON]; var id: String { fields["id"]?.text ?? "" }
init(_ f: [String: JSON]) { fields = f }
init(from d: Decoder) throws { fields = try [String: JSON](from: d) }
func encode(to e: Encoder) throws { try fields.encode(to: e) }
}
struct Snapshot: Codable { var tables: [String: [Record]]; var pending: [String: JSON] = [:] }
@main enum Probe {
static func main() throws {
 var reports: [[String: Any]] = []
 for count in [200, 2000] { for dense in [false, true] { for opaque in [false, true] {
 let base = dense ? "AAAA/" : String(repeating: "A", count: 79) + "/"
 let payload = String(repeating: base, count: 2_500_000/base.utf8.count)
 let future: JSON = opaque ? try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8)) : .number(1)
 var value = Snapshot(tables: ["tasks": (0..<count).map { n in
 var fields: [String: JSON] = ["id": .string("t-\(n)"), "title": .string("Task \(n)"), "description": .string("Café 🪴"), "future": future, "attachments": .array(n == 0 ? [.string(payload)] : [])]
 for k in 0..<15 { fields["ordinary-\(k)"] = .string("Keep ordinary field") }
 return Record(fields)
 }])
 let cache = SnapshotFieldEncodingCache()
 let initialBytes = try TaskfoldJSONEncoder().encode(value).count
 let admitted = cache.admits(value, knownBytes: initialBytes)
 let coldStart = Date(); _ = try admitted ? cache.encode(value) : TaskfoldJSONEncoder().encode(value); let cold = Date().timeIntervalSince(coldStart)
 var ordinary: [Double] = [], cached: [Double] = []
 for turn in 0..<9 {
 value.tables["tasks"]![0].fields["title"] = .string("Edited \(turn)")
 let a=Date(); let old = try TaskfoldJSONEncoder().encode(value); ordinary.append(Date().timeIntervalSince(a))
 let b=Date(); let fresh = try cache.admits(value, knownBytes: old.count) ? cache.encode(value) : TaskfoldJSONEncoder().encode(value); cached.append(Date().timeIntervalSince(b))
 let sorted = TaskfoldJSONEncoder(); sorted.outputFormatting = .sortedKeys
 let left = try sorted.encode(TaskfoldJSONDecoder().decode(Snapshot.self, from: old)), right = try sorted.encode(TaskfoldJSONDecoder().decode(Snapshot.self, from: fresh)); precondition(left == right)
 }
 reports.append(["fieldCacheAdmitted":admitted,"opaqueFutureNumbers":opaque,"admissionIncludedInTiming":true,"tasks":count,"payload":dense ? "dense-slashes" : "base64-like","ordinaryMedianSeconds":ordinary.sorted()[4],"cachedMedianSeconds":cached.sorted()[4],"coldCachedSeconds":cold,"exactColdReadback":true])
 }}}
 print(String(decoding:try JSONSerialization.data(withJSONObject:["optimization":"-O","productionCodecAndFieldCache":true,"ordinaryTaskAndSnapshotModels":false,"fullStore":false,"samples":9,"results":reports],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
}}
