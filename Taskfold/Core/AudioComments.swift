import Foundation
import CryptoKit

struct AudioCommentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static let invalid = Self(message: "This recording needs review. Use a complete AAC M4A file of up to two minutes and 8 MB.")
    static let changed = Self(message: "The workspace or task changed. Your recording has not been published.")
}

/// No URL, user-supplied filename or filesystem path is accepted by this wire format.
struct AudioCommentTarget: Codable, Equatable, Sendable {
    let task: UUID
    let generation: UUID
    let project: UUID?
    init(task: UUID, generation: UUID, project: UUID?) throws {
        guard task != Self.zero, generation != Self.zero, project != Self.zero else { throw AudioCommentFailure.changed }
        self.task = task; self.generation = generation; self.project = project
    }
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    var record: Record { Record(["task_id": .string(task.uuidString.lowercased()), "task_generation": .string(generation.uuidString.lowercased()), "project_id": project.map { .string($0.uuidString.lowercased()) } ?? .null]) }
    init(record: Record) throws {
        guard Set(record.fields.keys) == ["task_id", "task_generation", "project_id"], let task = UUID(uuidString: record.string("task_id")), let generation = UUID(uuidString: record.string("task_generation")), record["project_id"] == .null || UUID(uuidString: record.string("project_id")) != nil else { throw AudioCommentFailure.changed }
        try self.init(task: task, generation: generation, project: UUID(uuidString: record.string("project_id")))
    }
    init(from decoder: Decoder) throws { try self.init(record: Record(from: decoder)) }
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
    func objectName(asset: UUID) throws -> String {
        guard asset != Self.zero else { throw AudioCommentFailure.invalid }
        return "audio-comments/v1/\(task.uuidString.lowercased())/\(generation.uuidString.lowercased())/\(asset.uuidString.lowercased()).m4a"
    }
}

struct AudioCommentDescriptor: Codable, Equatable, Sendable {
    static let maximumBytes = 8_000_000
    static let maximumMilliseconds = 120_000
    let byteCount: Int
    let milliseconds: Int
    let sha256: String
    init(byteCount: Int, milliseconds: Int, sha256: String) throws {
        guard (1...Self.maximumBytes).contains(byteCount), (1...Self.maximumMilliseconds).contains(milliseconds), sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AudioCommentFailure.invalid }
        self.byteCount = byteCount; self.milliseconds = milliseconds; self.sha256 = sha256
    }
    var record: Record { Record(["version": .number(1), "mime_type": .string("audio/mp4"), "byte_count": .number(Double(byteCount)), "duration_ms": .number(Double(milliseconds)), "sha256": .string(sha256)]) }
    init(record: Record) throws {
        guard Set(record.fields.keys) == ["version", "mime_type", "byte_count", "duration_ms", "sha256"], record["version"] == .number(1), record["mime_type"] == .string("audio/mp4"), let bytes = TaskActivity.integer(record["byte_count"]), let duration = TaskActivity.integer(record["duration_ms"]), bytes <= Self.maximumBytes, duration <= Self.maximumMilliseconds else { throw AudioCommentFailure.invalid }
        try self.init(byteCount: Int(bytes), milliseconds: Int(duration), sha256: record.string("sha256"))
    }
    init(from decoder: Decoder) throws { try self.init(record: Record(from: decoder)) }
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
}

/// Bounded container validation and exact binary integrity, not a codec decoder.
/// Native adapters must also verify AVFoundation can decode the admitted audio.
struct AudioCommentClip: Sendable {
    let data: Data
    let descriptor: AudioCommentDescriptor
    /// Encoded-duration admission for callers that do not yet have native decode proof.
    init(data: Data) throws { try self.init(data: data, milliseconds: Self.encodedMilliseconds(in: data)) }
    /// A saved descriptor is bound to exact bytes; native decoding is still required
    /// before playback. This accepts AAC priming/remainder without trusting a URL.
    init(restoring data: Data, descriptor: AudioCommentDescriptor) throws {
        try self.init(data: data, milliseconds: descriptor.milliseconds)
        guard self.descriptor == descriptor else { throw AudioCommentFailure.invalid }
    }
    /// Called after complete native PCM decoding, using the presentation frame count.
    init(decoded data: Data, milliseconds: Int) throws { try self.init(data: data, milliseconds: milliseconds) }
    static func encodedMilliseconds(in data: Data) throws -> Int {
        guard !data.isEmpty, data.count <= AudioCommentDescriptor.maximumBytes else { throw AudioCommentFailure.invalid }
        return try AudioM4A(data).validate()
    }
    private init(data: Data, milliseconds: Int) throws {
        let encoded = try Self.encodedMilliseconds(in: data)
        guard (1...AudioCommentDescriptor.maximumMilliseconds).contains(milliseconds), abs(encoded - milliseconds) <= 1000 else { throw AudioCommentFailure.invalid }
        self.data = data
        let alphabet = Array("0123456789abcdef".utf8)
        let hex = SHA256.hash(data: data).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }
        descriptor = try AudioCommentDescriptor(byteCount: data.count, milliseconds: milliseconds, sha256: String(decoding: hex, as: UTF8.self))
    }
    func verifies(_ descriptor: AudioCommentDescriptor) -> Bool { self.descriptor == descriptor }
}

private struct AudioM4A {
    let bytes: [UInt8]
    init(_ data: Data) { bytes = Array(data) }
    struct Atom { let type: String; let payload: Range<Int> }
    func number(_ start: Int, _ size: Int, in range: Range<Int>) throws -> UInt64 {
        guard [2,4,8].contains(size), start >= range.lowerBound, start <= range.upperBound - size else { throw AudioCommentFailure.invalid }
        return bytes[start..<(start + size)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    func atoms(in range: Range<Int>) throws -> [Atom] {
        var position = range.lowerBound, result: [Atom] = []
        while position < range.upperBound {
            guard result.count < 4096 else { throw AudioCommentFailure.invalid }
            var size = try number(position, 4, in: range), header = 8
            guard position <= range.upperBound - header else { throw AudioCommentFailure.invalid }
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            if size == 1 { header = 16; size = try number(position + 8, 8, in: range) }
            if size == 0 { size = UInt64(range.upperBound - position) }
            guard size >= header, size <= UInt64(range.upperBound - position) else { throw AudioCommentFailure.invalid }
            let end = position + Int(size)
            result.append(Atom(type: type, payload: (position + header)..<end)); position = end
        }
        return result
    }
    func single(_ name: String, in atoms: [Atom]) throws -> Atom {
        let matches = atoms.filter { $0.type == name }
        guard matches.count == 1 else { throw AudioCommentFailure.invalid }; return matches[0]
    }
    func duration(_ atom: Atom) throws -> Int {
        guard let version = bytes[atom.payload].first, version <= 1 else { throw AudioCommentFailure.invalid }
        let offset = atom.payload.lowerBound + (version == 0 ? 12 : 20)
        let scale = try number(offset, 4, in: atom.payload), ticks = try number(offset + 4, version == 0 ? 4 : 8, in: atom.payload)
        guard scale > 0, ticks > 0, ticks <= UInt64(AudioCommentDescriptor.maximumMilliseconds + 1000) * scale / 1000 else { throw AudioCommentFailure.invalid }
        return Int((ticks * 1000 + scale - 1) / scale)
    }
    func validate() throws -> Int {
        let top = try atoms(in: bytes.indices), brand = try single("ftyp", in: top)
        guard brand.payload.count >= 8, brand.payload.count % 4 == 0 else { throw AudioCommentFailure.invalid }
        let brands = stride(from: brand.payload.lowerBound, to: brand.payload.upperBound, by: 4).filter { $0 != brand.payload.lowerBound + 4 }.map { String(decoding: bytes[$0..<($0 + 4)], as: UTF8.self) }
        guard brands.contains(where: { ["M4A ", "isom", "iso2", "mp41", "mp42"].contains($0) }), top.contains(where: { $0.type == "mdat" && !$0.payload.isEmpty }), !top.contains(where: { $0.type == "moof" }) else { throw AudioCommentFailure.invalid }
        let movie = try atoms(in: single("moov", in: top).payload)
        let movieDuration = try duration(single("mvhd", in: movie))
        let track = try single("trak", in: movie), media = try atoms(in: single("mdia", in: atoms(in: track.payload)).payload)
        let trackDuration = try duration(single("mdhd", in: media))
        let handler = try single("hdlr", in: media)
        guard handler.payload.count >= 12, String(decoding: bytes[(handler.payload.lowerBound + 8)..<(handler.payload.lowerBound + 12)], as: UTF8.self) == "soun" else { throw AudioCommentFailure.invalid }
        let info = try atoms(in: single("minf", in: media).payload), samples = try atoms(in: single("stbl", in: info).payload)
        let description = try single("stsd", in: samples)
        guard try number(description.payload.lowerBound + 4, 4, in: description.payload) == 1 else { throw AudioCommentFailure.invalid }
        let entries = try atoms(in: (description.payload.lowerBound + 8)..<description.payload.upperBound)
        let entry = try single("mp4a", in: entries)
        guard entries.count == 1, entry.payload.count >= 28, abs(trackDuration - movieDuration) <= 1000 else { throw AudioCommentFailure.invalid }
        return max(movieDuration, trackDuration)
    }
}

/// Frozen publication intent survives an uncertain response; editing may not
/// create another comment until the previous operation has been reconciled.
struct AudioCommentPublication: Codable, Equatable, Sendable {
    let account: UUID
    let operation: UUID
    let comment: UUID
    let asset: UUID
    let target: AudioCommentTarget
    let caption: String
    let descriptor: AudioCommentDescriptor
    init(account: UUID, target: AudioCommentTarget, caption: String, descriptor: AudioCommentDescriptor, operation: UUID = UUID(), comment: UUID = UUID(), asset: UUID = UUID()) throws {
        guard [account, operation, comment, asset].allSatisfy({ $0 != AudioCommentTarget.zero }) else { throw AudioCommentFailure.changed }
        try Self.validateCaption(caption)
        self.account = account; self.operation = operation; self.comment = comment; self.asset = asset; self.target = target; self.caption = caption; self.descriptor = descriptor
    }
    static func validateCaption(_ caption: String) throws { guard caption.utf8.count <= 4000, !caption.contains("\0") else { throw AudioCommentFailure(message: "Keep the caption below 4 KB. Your recording is still here.") } }
    var record: Record { Record(["version": .number(1), "account": .string(account.uuidString.lowercased()), "operation_id": .string(operation.uuidString.lowercased()), "comment_id": .string(comment.uuidString.lowercased()), "asset_id": .string(asset.uuidString.lowercased()), "target": .object(target.record.fields), "caption": .string(caption), "audio": .object(descriptor.record.fields)]) }
    init(record: Record) throws {
        guard Set(record.fields.keys) == ["version", "account", "operation_id", "comment_id", "asset_id", "target", "caption", "audio"], record["version"] == .number(1), let account = UUID(uuidString: record.string("account")), let operation = UUID(uuidString: record.string("operation_id")), let comment = UUID(uuidString: record.string("comment_id")), let asset = UUID(uuidString: record.string("asset_id")), case .string(let caption) = record["caption"] else { throw AudioCommentFailure.changed }
        try self.init(account: account, target: AudioCommentTarget(record: Record(record["target"].object)), caption: caption, descriptor: AudioCommentDescriptor(record: Record(record["audio"].object)), operation: operation, comment: comment, asset: asset)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.record == rhs.record && lhs.caption.utf8.elementsEqual(rhs.caption.utf8) }
    func sameIntent(as other: Self) -> Bool { self == other }
    init(from decoder: Decoder) throws { try self.init(record: Record(from: decoder)) }
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
}

struct AudioCommentDraft: Sendable {
    enum Phase: Equatable, Sendable { case ready, authorizing, recording, finishing, review, sending, unconfirmed, published, closed }
    let workspace: WorkspaceBinding
    let target: AudioCommentTarget
    private(set) var phase: Phase = .ready
    private(set) var token: UUID?
    private(set) var clip: AudioCommentClip?
    private(set) var caption = ""
    private(set) var publication: AudioCommentPublication?
    func matches(workspace: WorkspaceBinding, target: AudioCommentTarget) -> Bool { self.target == target && self.workspace.generation == workspace.generation && !self.workspace.account.isEmpty && self.workspace.account.utf8.elementsEqual(workspace.account.utf8) }
    mutating func begin(workspace: WorkspaceBinding, target: AudioCommentTarget) throws -> UUID {
        guard matches(workspace: workspace, target: target), [.ready, .review].contains(phase), publication == nil else { throw AudioCommentFailure.changed }
        let token = UUID(); self.token = token; phase = .authorizing; return token
    }
    func accepts(_ token: UUID, workspace: WorkspaceBinding, target: AudioCommentTarget) -> Bool { self.token == token && [.authorizing, .recording, .finishing].contains(phase) && matches(workspace: workspace, target: target) }
    mutating func started(_ token: UUID, workspace: WorkspaceBinding, target: AudioCommentTarget) {
        guard phase == .authorizing, accepts(token, workspace: workspace, target: target) else { return }; phase = .recording
    }
    mutating func finishing() { if phase == .recording { phase = .finishing } }
    @discardableResult mutating func receive(_ clip: AudioCommentClip, token: UUID, workspace: WorkspaceBinding, target: AudioCommentTarget) -> Bool {
        guard [.recording, .finishing].contains(phase), accepts(token, workspace: workspace, target: target) else { return false }
        self.clip = clip; self.token = nil; phase = .review; return true
    }
    mutating func failed(_ token: UUID) { guard self.token == token else { return }; self.token = nil; phase = clip == nil ? .ready : .review }
    mutating func editCaption(_ caption: String) throws { guard [.ready, .review].contains(phase), publication == nil else { throw AudioCommentFailure.changed }; try AudioCommentPublication.validateCaption(caption); self.caption = caption }
    mutating func preparePublication(workspace: WorkspaceBinding, target: AudioCommentTarget) throws -> AudioCommentPublication {
        guard matches(workspace: workspace, target: target), phase == .review, publication == nil, let clip, let account = UUID(uuidString: workspace.account) else { throw AudioCommentFailure.changed }
        let intent = try AudioCommentPublication(account: account, target: target, caption: caption, descriptor: clip.descriptor)
        publication = intent; phase = .sending; return intent
    }
    mutating func unconfirmed() { if phase == .sending { phase = .unconfirmed } }
    mutating func retry(workspace: WorkspaceBinding, target: AudioCommentTarget) throws -> AudioCommentPublication {
        guard phase == .unconfirmed, matches(workspace: workspace, target: target), let publication else { throw AudioCommentFailure.changed }; phase = .sending; return publication
    }
    @discardableResult mutating func confirmed(_ intent: AudioCommentPublication, workspace: WorkspaceBinding, target: AudioCommentTarget) -> Bool {
        guard [.sending, .unconfirmed].contains(phase), matches(workspace: workspace, target: target), publication?.sameIntent(as: intent) == true else { return false }; phase = .published; return true
    }
    mutating func restore(_ clip: AudioCommentClip, caption: String, workspace: WorkspaceBinding, target: AudioCommentTarget) throws {
        guard matches(workspace: workspace, target: target), [.ready, .review].contains(phase), publication == nil else { throw AudioCommentFailure.changed }
        try AudioCommentPublication.validateCaption(caption)
        self.clip = clip; self.caption = caption; token = nil; phase = .review
    }
    mutating func close() { token = nil; phase = .closed; clip = nil; caption = ""; publication = nil }

}


/// Personal root admission for device-private recordings. Editing permission and
/// live workspace availability remain the app Store's independent responsibility.
enum AudioCommentTaskAdmission {
    static func target(account: String, task: Record, projects: [Record]) throws -> AudioCommentTarget {
        _ = try AudioCommentOwner(account)
        guard !account.isEmpty, task.string("user_id").utf8.elementsEqual(account.utf8), TaskKind(task) != .unsupported,
              let id = UUID(uuidString: task.id), let generation = UUID(uuidString: task.string("task_generation")) else { throw AudioCommentFailure.changed }
        let projectID: UUID?
        switch task["project_id"] {
        case .null: projectID = nil
        case .string(let value) where value.isEmpty: projectID = nil
        case .string(let value):
            guard let parsed = UUID(uuidString: value), parsed != AudioCommentTarget.zero,
                  projects.filter({ $0.id.utf8.elementsEqual(value.utf8) }).count == 1,
                  let project = projects.first(where: { $0.id.utf8.elementsEqual(value.utf8) }),
                  project.string("user_id").utf8.elementsEqual(account.utf8),
                  project["team_id"] == .null || project["team_id"] == .string(""),
                  project["is_archived"] == .null || project["is_archived"] == .bool(false),
                  !ProjectOrganization.archived(value, in: projects) else { throw AudioCommentFailure.changed }
            projectID = parsed
        default: throw AudioCommentFailure.changed
        }
        return try .init(task: id, generation: generation, project: projectID)
    }
    static func applicationDirectory(bundleIdentifier: String) throws -> String {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 256, !bundleIdentifier.contains("\0") else { throw AudioCommentFailure.changed }
        return "app-v1-" + SHA256.hash(data: Data(bundleIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func storageDirectory(origin: String?) throws -> String {
        guard let origin else { return "local-v1" }
        guard let url = URLComponents(string: origin), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty else { throw AudioCommentFailure.changed }
        return "origin-v1-" + SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Portable, account-free copy. Decoding admits bounded container/integrity data;
/// a consumer must still fully decode AAC before playback or importing a draft.
struct AudioCommentPortableRecording: Sendable {
    static let format = "taskfold-recording-backup-v1"
    static let maximumFileBytes = ((AudioCommentDescriptor.maximumBytes + 2) / 3) * 4 + 40_000
    let caption: String
    let clip: AudioCommentClip
    init(caption: String, clip: AudioCommentClip) throws {
        try AudioCommentPublication.validateCaption(caption)
        self.caption = caption; self.clip = clip
    }
    func encoded() throws -> Data {
        let value = Record(["format": .string(Self.format), "caption": .string(caption),
                            "descriptor": .object(clip.descriptor.record.fields), "audio_base64": .string(clip.data.base64EncodedString())])
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumFileBytes else { throw AudioCommentFailure.invalid }
        return data
    }
    init(encoded data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else { throw AudioCommentFailure.invalid }
        let value = try TaskfoldJSONDecoder().decode(Record.self, from: data)
        guard Set(value.fields.keys) == ["format", "caption", "descriptor", "audio_base64"],
              value["format"] == .string(Self.format), case .string(let caption) = value["caption"],
              case .object(let descriptor) = value["descriptor"], case .string(let audio) = value["audio_base64"],
              audio.utf8.count <= ((AudioCommentDescriptor.maximumBytes + 2) / 3) * 4,
              let bytes = Data(base64Encoded: audio) else { throw AudioCommentFailure.invalid }
        try self.init(caption: caption, clip: .init(restoring: bytes, descriptor: .init(record: Record(descriptor))))
    }
}
