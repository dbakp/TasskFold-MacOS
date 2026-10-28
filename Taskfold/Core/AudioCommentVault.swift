import Foundation
import CryptoKit
import Darwin

struct AudioCommentStorageFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    static let unreadable = Self(message: "Audio drafts could not be read safely. Your saved recordings have not been replaced.")
    static let conflict = Self(message: "This audio draft changed in another window. Reload it before saving.")
    static let busy = Self(message: "Audio drafts are being saved. Try again in a moment.")
    static let unconfirmedSave = Self(message: "The audio Save is prepared on this device. Retry the same Save to finish safely.")
    static let reviewClaimed = Self(message: "This recovered review was saved or changed in another editor. Save a separate draft to keep your version.")
    static let discardPending = Self(message: "Discard is kept on this device. Finish discarding this recording.")
    static let alreadySaved = Self(message: "This recording is already saved. Finish saving before deleting the saved draft.")
    static let stageNeedsRecovery = Self(message: "An earlier recording action needs recovery before another copy can be saved.")
    static let full = Self(message: "Audio draft storage is full. Review your saved drafts before recording more.")
}

struct AudioCommentOwner: Equatable, Sendable {
    let account: String
    init(_ account: String) throws {
        guard !account.isEmpty, account.utf8.count <= 256, !account.contains("\0") else { throw AudioCommentFailure.changed }
        self.account = account
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.account.utf8.elementsEqual(rhs.account.utf8) }
    var directoryName: String { SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// Restorable local review, independent of a cloud publication or workspace incarnation.
/// A restored draft must be admitted against the current task before it can be used.
struct AudioCommentSavedDraft: Equatable, Sendable {
    let id: UUID
    let revision: UUID
    let owner: AudioCommentOwner
    let target: AudioCommentTarget
    let caption: String
    let clip: AudioCommentClip
    let origin: AudioCommentReviewReference?
    init(owner: AudioCommentOwner, target: AudioCommentTarget, caption: String, clip: AudioCommentClip, id: UUID = UUID(), revision: UUID = UUID(), origin: AudioCommentReviewReference? = nil) throws {
        guard id != AudioCommentTarget.zero, revision != AudioCommentTarget.zero else { throw AudioCommentFailure.changed }
        try AudioCommentPublication.validateCaption(caption)
        if let origin { guard origin.id != AudioCommentTarget.zero, origin.revision != AudioCommentTarget.zero else { throw AudioCommentFailure.changed } }
        self.origin = origin
        self.owner = owner; self.target = target; self.caption = caption; self.clip = clip; self.id = id; self.revision = revision
    }
    func replacing(caption: String, clip: AudioCommentClip) throws -> Self {
        if self.caption.utf8.elementsEqual(caption.utf8), self.clip.data == clip.data { return self }
        return try .init(owner: owner, target: target, caption: caption, clip: clip, id: id, origin: origin)
    }
    func carryingOrigin(_ origin: AudioCommentReviewReference?) throws -> Self {
        if self.origin == origin { return self }
        return try .init(owner: owner, target: target, caption: caption, clip: clip, id: id, origin: origin)
    }
    func sameContent(as other: Self) -> Bool {
        owner == other.owner && target == other.target && caption.utf8.elementsEqual(other.caption.utf8) && clip.data == other.clip.data
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.origin == rhs.origin && lhs.owner == rhs.owner && lhs.target == rhs.target && lhs.caption.utf8.elementsEqual(rhs.caption.utf8) && lhs.clip.data == rhs.clip.data
    }
    func encoded(recovery: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try PropertyListSerialization.data(fromPropertyList: [
            "format": recovery ? "taskfold-audio-recovery-v2" : "taskfold-audio-review-v2", "account": owner.account,
            "id": id.uuidString.lowercased(), "revision": revision.uuidString.lowercased(),
            "target": try encoder.encode(target), "caption": caption,
            "descriptor": try encoder.encode(clip.descriptor), "audio": clip.data, "origin": try encoder.encode(origin)
        ], format: .binary, options: 0)
    }
    init(encoded data: Data, owner: AudioCommentOwner, recovery: Bool = false) throws {
        guard !data.isEmpty, data.count <= AudioCommentVault.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any], format == .binary,
              ((fields["format"] as? String == (recovery ? "taskfold-audio-recovery-v1" : "taskfold-audio-review-v1") && Set(fields.keys) == ["format", "account", "id", "revision", "target", "caption", "descriptor", "audio"]) ||
               (fields["format"] as? String == (recovery ? "taskfold-audio-recovery-v2" : "taskfold-audio-review-v2") && Set(fields.keys) == ["format", "account", "id", "revision", "target", "caption", "descriptor", "audio", "origin"])) , let account = fields["account"] as? String,
              account.utf8.elementsEqual(owner.account.utf8), let idText = fields["id"] as? String, let id = UUID(uuidString: idText),
              let revisionText = fields["revision"] as? String, let revision = UUID(uuidString: revisionText),
              let targetData = fields["target"] as? Data, targetData.count <= 4096,
              let descriptorData = fields["descriptor"] as? Data, descriptorData.count <= 4096,
              let caption = fields["caption"] as? String, let audio = fields["audio"] as? Data else { throw AudioCommentStorageFailure.unreadable }
        let origin: AudioCommentReviewReference?
        if let data = fields["origin"] as? Data {
            guard data.count <= 512 else { throw AudioCommentStorageFailure.unreadable }
            origin = try JSONDecoder().decode(AudioCommentReviewReference?.self, from: data)
        } else {
            guard fields["origin"] == nil else { throw AudioCommentStorageFailure.unreadable }; origin = nil
        }
        let descriptor = try JSONDecoder().decode(AudioCommentDescriptor.self, from: descriptorData)
        let clip = try AudioCommentClip(restoring: audio, descriptor: descriptor)
        try self.init(owner: owner, target: JSONDecoder().decode(AudioCommentTarget.self, from: targetData), caption: caption, clip: clip, id: id, revision: revision, origin: origin)
    }
}



struct AudioCommentReviewReference: Codable, Hashable, Sendable {
    let id: UUID
    let revision: UUID
    init(_ draft: AudioCommentSavedDraft) { id = draft.id; revision = draft.revision }
}

/// Durable local Save authorization, separate from cloud publication. The intent
/// remains until the exact draft and recovery cleanup are durably acknowledged.
enum AudioCommentLocalSaveState: Sendable { case unprepared, prepared, settled }

enum AudioCommentSavePhase: String, Sendable { case saving, discarding }
struct AudioCommentSaveRedirect: Error { let intent: AudioCommentSaveIntent }
struct AudioCommentDraftCatalog: Sendable {
    let drafts: [AudioCommentSavedDraft]
    let reviews: [AudioCommentSavedDraft]
    let saves: [AudioCommentSaveIntent]
}

/// Exact cleanup permission for one interrupted local draft/review. No path or
/// publication intent can be supplied through this reference.
struct AudioCommentStageReference: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case draft, review }
    let id: UUID
    let kind: Kind
    let sha256: String
    init(_ write: AudioCommentInterruptedWrite) throws {
        guard write.id != AudioCommentTarget.zero else { throw AudioCommentFailure.changed }
        switch write.payload { case .draft: kind = .draft; case .review: kind = .review; default: throw AudioCommentFailure.changed }
        id = write.id; sha256 = SHA256.hash(data: write.bytes).map { String(format: "%02x", $0) }.joined()
    }
    init(from decoder: Decoder) throws {
        let value = try Record(from: decoder)
        guard Set(value.fields.keys) == ["id", "kind", "sha256"], let id = UUID(uuidString: value.string("id")), id != AudioCommentTarget.zero,
              let kind = Kind(rawValue: value.string("kind")), value.string("sha256").utf8.count == 64,
              value.string("sha256").utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AudioCommentStorageFailure.unreadable }
        self.id = id; self.kind = kind; sha256 = value.string("sha256")
    }
    func encode(to encoder: Encoder) throws {
        try Record(["id": .string(id.uuidString.lowercased()), "kind": .string(kind.rawValue), "sha256": .string(sha256)]).encode(to: encoder)
    }
    fileprivate var filename: String { ".write-" + id.uuidString.lowercased() }
    fileprivate func matches(_ data: Data) -> Bool { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256 }
}

struct AudioCommentSaveIntent: Equatable, Sendable {
    let id: UUID
    let next: AudioCommentSavedDraft
    let base: UUID?
    let reviews: [AudioCommentReviewReference]
    let phase: AudioCommentSavePhase
    let stage: AudioCommentStageReference?
    init(next: AudioCommentSavedDraft, base: UUID?, reviews: [AudioCommentReviewReference], id: UUID = UUID(), phase: AudioCommentSavePhase = .saving, stage: AudioCommentStageReference? = nil) throws {
        guard id != AudioCommentTarget.zero, base != AudioCommentTarget.zero,
              reviews.count <= 3, Set(reviews).count == reviews.count,
              reviews.allSatisfy({ $0.id != AudioCommentTarget.zero && $0.revision != AudioCommentTarget.zero }) else { throw AudioCommentStorageFailure.conflict }
        guard stage == nil || (base == nil && reviews.isEmpty && next.origin == nil) else { throw AudioCommentStorageFailure.conflict }
        self.id = id; self.next = next; self.base = base; self.reviews = reviews; self.phase = phase; self.stage = stage
    }
    func separateCopy() throws -> Self {
        guard phase == .saving else { throw AudioCommentStorageFailure.discardPending }
        return try .init(next: .init(owner: next.owner, target: next.target, caption: next.caption, clip: next.clip), base: nil, reviews: reviews, id: id, stage: stage)
    }
    func markingDiscard() throws -> Self { try .init(next: next, base: base, reviews: reviews, id: id, phase: .discarding, stage: stage) }
    func sameAuthorization(as other: Self) -> Bool { id == other.id && next == other.next && base == other.base && reviews == other.reviews && stage == other.stage }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var fields: [String: Any] = ["format": stage == nil ? "taskfold-audio-save-v2" : "taskfold-audio-save-v3", "phase": phase.rawValue, "account": next.owner.account, "id": id.uuidString.lowercased(), "next": try next.encoded(), "base": base?.uuidString.lowercased() ?? "", "reviews": try encoder.encode(reviews)]
        if let stage { fields["stage"] = try encoder.encode(stage) }
        return try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
    }
    init(encoded data: Data, owner: AudioCommentOwner) throws {
        guard !data.isEmpty, data.count <= AudioCommentVault.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any], format == .binary,
              ((Set(fields.keys) == ["format", "account", "id", "next", "base", "reviews"] && fields["format"] as? String == "taskfold-audio-save-v1") ||
               (Set(fields.keys) == ["format", "account", "id", "next", "base", "reviews", "phase"] && fields["format"] as? String == "taskfold-audio-save-v2") ||
               (Set(fields.keys) == ["format", "account", "id", "next", "base", "reviews", "phase", "stage"] && fields["format"] as? String == "taskfold-audio-save-v3")),
              let account = fields["account"] as? String, account.utf8.elementsEqual(owner.account.utf8),
              let idText = fields["id"] as? String, let id = UUID(uuidString: idText),
              let payload = fields["next"] as? Data, let baseText = fields["base"] as? String,
              baseText.isEmpty || UUID(uuidString: baseText) != nil,
              let refs = fields["reviews"] as? Data, refs.count <= 4096 else { throw AudioCommentStorageFailure.unreadable }
        let phase: AudioCommentSavePhase
        if let text = fields["phase"] as? String, let value = AudioCommentSavePhase(rawValue: text) { phase = value }
        else { guard fields["phase"] == nil else { throw AudioCommentStorageFailure.unreadable }; phase = .saving }
        let stage: AudioCommentStageReference?
        if fields["format"] as? String == "taskfold-audio-save-v3" {
            guard let bytes = fields["stage"] as? Data, bytes.count <= 512 else { throw AudioCommentStorageFailure.unreadable }
            stage = try JSONDecoder().decode(AudioCommentStageReference.self, from: bytes)
        } else { stage = nil }
        try self.init(next: AudioCommentSavedDraft(encoded: payload, owner: owner), base: UUID(uuidString: baseText), reviews: JSONDecoder().decode([AudioCommentReviewReference].self, from: refs), id: id, phase: phase, stage: stage)
    }
}

struct AudioCommentInterruptedWrite: Identifiable, Sendable {
    enum Payload: Sendable { case draft(AudioCommentSavedDraft), review(AudioCommentSavedDraft), save(AudioCommentSaveIntent), pending(AudioCommentPending) }
    let id: UUID
    let payload: Payload
    fileprivate let bytes: Data
}

struct AudioCommentInterruptedCatalog: Sendable {
    let writes: [AudioCommentInterruptedWrite]
    let unreadableCount: Int
}

/// An account-private, process-locked store. No App Group or portable snapshot refs.
/// All payload IO uses the opened directory; symlinks and hard-linked files refuse.
struct AudioCommentVault: Sendable {
    static let maximumFileBytes = 8_100_000
    static let maximumEntries = 20
    static let maximumTotalBytes = 50_000_000
    enum Checkpoint: Sendable { case beforeRename, afterRename, afterSaveJournal, afterDraftCommit, afterStageCleanup, afterDiscardJournal, afterExpiredReviewDiscard, beforeSaveState }
    let applicationSupport: URL
    let owner: AudioCommentOwner
    var fault: (@Sendable (Checkpoint) throws -> Void)? = nil
    var directory: URL { applicationSupport.appendingPathComponent("AudioCommentsPrivate", isDirectory: true).appendingPathComponent(owner.directoryName, isDirectory: true) }
    private func name(_ prefix: String, _ id: UUID) -> String { prefix + id.uuidString.lowercased() + ".bin" }
    private func childDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let created = mkdirat(parent, name, 0o700) == 0
        guard created || errno == EEXIST else { throw AudioCommentStorageFailure.unreadable }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioCommentStorageFailure.unreadable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0, !created || fsync(parent) == 0 else { Darwin.close(fd); throw AudioCommentStorageFailure.unreadable }
        return fd
    }
    private func locked<T>(_ body: (Int32) throws -> T) throws -> T { try withLock { folder, _ in try body(folder) } }
    private func withLock<T>(_ body: (Int32, Int32) throws -> T) throws -> T {
        let parent = Darwin.open(applicationSupport.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AudioCommentStorageFailure.unreadable }; defer { Darwin.close(parent) }
        let root = try childDirectory("AudioCommentsPrivate", parent: parent); defer { Darwin.close(root) }
        let folder = try childDirectory(owner.directoryName, parent: root); defer { Darwin.close(folder) }
        let lock = openat(folder, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw AudioCommentStorageFailure.unreadable }; defer { Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), fchmod(lock, 0o600) == 0 else { throw AudioCommentStorageFailure.unreadable }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.busy }; defer { _ = flock(lock, LOCK_UN) }
        return try body(folder, lock)
    }
    /// One fixed-size nonce in the already-private lock file fences automatic
    /// journal creation after any completed/pending discard. It adds no payload
    /// file, growing receipt log or quota-consuming tombstone.
    private func readDepartureFence(_ lock: Int32) throws -> UUID? {
        var info = stat()
        guard fstat(lock, &info) == 0 else { throw AudioCommentStorageFailure.unreadable }
        if info.st_size == 0 { return nil }
        guard info.st_size == 36 else { throw AudioCommentStorageFailure.unreadable }
        var bytes = [UInt8](repeating: 0, count: 36)
        guard bytes.withUnsafeMutableBytes({ pread(lock, $0.baseAddress, 36, 0) }) == 36,
              let token = UUID(uuidString: String(decoding: bytes, as: UTF8.self)),
              token.uuidString.lowercased().utf8.elementsEqual(bytes) else { throw AudioCommentStorageFailure.unreadable }
        return token
    }
    private func writeDepartureFence(_ token: UUID, lock: Int32) throws {
        let bytes = Array(token.uuidString.lowercased().utf8)
        guard bytes.withUnsafeBytes({ pwrite(lock, $0.baseAddress, bytes.count, 0) }) == bytes.count,
              ftruncate(lock, off_t(bytes.count)) == 0, fsync(lock) == 0 else { throw AudioCommentStorageFailure.unreadable }
    }
    func departureFence() throws -> UUID {
        try withLock { folder, lock in
            let existing = try readDepartureFence(lock), token = existing ?? UUID()
            if existing == nil { try writeDepartureFence(token, lock: lock) }
            guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
            return token
        }
    }
    private func read(_ name: String, folder: Int32) throws -> Data? {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw AudioCommentStorageFailure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
        var data = Data()
        while data.count <= Self.maximumFileBytes {
            guard let chunk = try handle.read(upToCount: min(65536, Self.maximumFileBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
        return data
    }
    private func names(folder: Int32) throws -> [String] {
        // A separate open file description avoids sharing the directory enumeration offset.
        let fd = openat(folder, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw AudioCommentStorageFailure.unreadable }
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw AudioCommentStorageFailure.unreadable }
        defer { closedir(stream) }
        var names: [String] = []
        var totalBytes: Int64 = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw AudioCommentStorageFailure.unreadable }; break }
            let value = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if value == "." || value == ".." || value == ".lock" { continue }
            // An interrupted pre-rename staging file is preserved, not treated as published work.
            let staged = value.hasPrefix(".write-") && UUID(uuidString: String(value.dropFirst(7))) != nil
            let committed = ["draft-", "pending-", "review-", "save-"].contains { prefix in value.hasPrefix(prefix) && value.hasSuffix(".bin") && UUID(uuidString: String(value.dropFirst(prefix.count).dropLast(4))) != nil }
            guard staged || committed else { throw AudioCommentStorageFailure.unreadable }
            var info = stat()
            guard fstatat(folder, value, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
            totalBytes += info.st_size
            guard totalBytes <= Self.maximumTotalBytes + Self.maximumFileBytes else { throw AudioCommentStorageFailure.full }
            names.append(value)
            guard names.count <= Self.maximumEntries + 1 else { throw AudioCommentStorageFailure.full }
        }
        return names.sorted()
    }
    private func write(_ data: Data, name: String, folder: Int32) throws {
        guard data.count <= Self.maximumFileBytes else { throw AudioCommentStorageFailure.full }
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let fd = openat(folder, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AudioCommentStorageFailure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlinkat(folder, temporary, 0) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.appendingPathComponent(temporary).path)
        #endif
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        try fault?(.beforeRename)
        guard renameat(folder, temporary, folder, name) == 0 else { throw AudioCommentStorageFailure.unreadable }
        try fault?(.afterRename)
        guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
    }
    private func admit(_ data: Data, replacing name: String, excludingStage: String? = nil, folder: Int32) throws {
        let entries = try names(folder: folder).filter { $0 != excludingStage }
        guard entries.contains(name) || entries.count < Self.maximumEntries else { throw AudioCommentStorageFailure.full }
        var bytes = data.count
        for entry in entries where entry != name {
            var info = stat()
            guard fstatat(folder, entry, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
            bytes += Int(info.st_size)
            guard bytes <= Self.maximumTotalBytes else { throw AudioCommentStorageFailure.full }
        }
    }

    /// Complete pre-rename writes are explicitly reviewed, never silently discarded.
    /// Incomplete stages remain on disk and produce a recovery error.
    func interruptedWrites() throws -> [AudioCommentInterruptedWrite] {
        let catalog = try interruptedCatalog()
        guard catalog.unreadableCount == 0 else { throw AudioCommentStorageFailure.unreadable }
        return catalog.writes
    }
    /// Decode failures never remove a file or hide other complete stages. Unsafe
    /// filesystem entries still fail the whole scan before any payload is read.
    func interruptedCatalog() throws -> AudioCommentInterruptedCatalog {
        try locked { folder in
            var writes: [AudioCommentInterruptedWrite] = [], unreadable = 0
            for filename in try names(folder: folder).filter({ $0.hasPrefix(".write-") }) {
                guard let id = UUID(uuidString: String(filename.dropFirst(7))), let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
                let payload: AudioCommentInterruptedWrite.Payload
                do {
                    if let draft = try? AudioCommentSavedDraft(encoded: data, owner: owner) { payload = .draft(draft) }
                    else if let review = try? AudioCommentSavedDraft(encoded: data, owner: owner, recovery: true) { payload = .review(review) }
                    else if let save = try? AudioCommentSaveIntent(encoded: data, owner: owner) { payload = .save(save) }
                    else { payload = .pending(try AudioCommentPending(encoded: data, account: cloudAccount())) }
                } catch { unreadable += 1; continue }
                writes.append(.init(id: id, payload: payload, bytes: data))
            }
            return .init(writes: writes, unreadableCount: unreadable)
        }
    }
    /// A changed saved review requires an explicit current revision; pending
    /// publications can recover only their exact, immutable operation intent.
    func recover(_ candidate: AudioCommentInterruptedWrite, replacing revision: UUID? = nil) throws {
        try locked { folder in
            let stage = ".write-" + candidate.id.uuidString.lowercased()
            guard let data = try read(stage, folder: folder), data == candidate.bytes else { throw AudioCommentStorageFailure.conflict }
            let destination: String
            var identical = false
            switch candidate.payload {
            case .draft(let draft), .review(let draft):
                let recovery: Bool
                if case .review = candidate.payload { recovery = true } else { recovery = false }
                guard draft.owner == owner, try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: recovery) == draft else { throw AudioCommentStorageFailure.conflict }
                destination = name(recovery ? "review-" : "draft-", draft.id)
                if !recovery, try records(folder: folder).saves.contains(where: { $0.next.id == draft.id }) {
                    throw AudioCommentStorageFailure.unconfirmedSave
                }
                if let bytes = try read(destination, folder: folder) {
                    let current = try AudioCommentSavedDraft(encoded: bytes, owner: owner, recovery: recovery)
                    identical = current == draft
                    guard identical || current.id == draft.id && current.target == draft.target && current.origin == draft.origin && current.revision == revision && current.revision != draft.revision else { throw AudioCommentStorageFailure.conflict }
                } else if revision != nil { throw AudioCommentStorageFailure.conflict }
            case .save(let save):
                guard save.next.owner == owner, try AudioCommentSaveIntent(encoded: data, owner: owner) == save, revision == nil else { throw AudioCommentStorageFailure.conflict }
                destination = name("save-", save.id)
                if let bytes = try read(destination, folder: folder) {
                    guard try AudioCommentSaveIntent(encoded: bytes, owner: owner) == save else { throw AudioCommentStorageFailure.conflict }
                    identical = true
                }
            case .pending(let pending):
                let decoded = try AudioCommentPending(encoded: data, account: cloudAccount())
                guard decoded.publication.sameIntent(as: pending.publication), decoded.clip.data == pending.clip.data, revision == nil else { throw AudioCommentStorageFailure.conflict }
                destination = name("pending-", pending.publication.operation)
                if let bytes = try read(destination, folder: folder) {
                    let current = try AudioCommentPending(encoded: bytes, account: cloudAccount())
                    guard current.publication.sameIntent(as: pending.publication), current.clip.data == pending.clip.data else { throw AudioCommentStorageFailure.conflict }
                    identical = true
                }
            }
            if identical {
                guard unlinkat(folder, stage, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
            } else {
                try admit(data, replacing: destination, excludingStage: stage, folder: folder)
                guard renameat(folder, stage, folder, destination) == 0 else { throw AudioCommentStorageFailure.unreadable }
            }
            guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
        }
    }

    func drafts(recovery: Bool = false) throws -> [AudioCommentSavedDraft] {
        let prefix = recovery ? "review-" : "draft-"
        return try locked { folder in try names(folder: folder).filter { $0.hasPrefix(prefix) }.map { filename in
            guard let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
            let draft = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: recovery)
            guard filename == name(prefix, draft.id) else { throw AudioCommentStorageFailure.unreadable }; return draft
        } }
    }
    func save(_ draft: AudioCommentSavedDraft, replacing revision: UUID? = nil, recovery: Bool = false) throws {
        guard draft.owner == owner else { throw AudioCommentFailure.changed }
        try locked { folder in
            let filename = name(recovery ? "review-" : "draft-", draft.id)
            if !recovery {
                for pending in try records(folder: folder).saves where pending.next.id == draft.id { throw AudioCommentStorageFailure.unconfirmedSave }
            }
            if let data = try read(filename, folder: folder) {
                let current = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: recovery)
                if current == draft { guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }; return }
                guard current.id == draft.id, current.target == draft.target, current.origin == draft.origin, current.revision == revision, current.revision != draft.revision else { throw AudioCommentStorageFailure.conflict }
            } else if revision != nil { throw AudioCommentStorageFailure.conflict }
            let data = try draft.encoded(recovery: recovery); try admit(data, replacing: filename, folder: folder); try write(data, name: filename, folder: folder)
        }
    }
    func discardDraft(_ id: UUID, revision: UUID, recovery: Bool = false) throws {
        try locked { folder in
            let filename = name(recovery ? "review-" : "draft-", id)
            if !recovery {
                for entry in try names(folder: folder).filter({ $0.hasPrefix("save-") }) {
                    guard let bytes = try read(entry, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
                    if try AudioCommentSaveIntent(encoded: bytes, owner: owner).next.id == id { throw AudioCommentStorageFailure.unconfirmedSave }
                }
            }
            if let data = try read(filename, folder: folder) {
                let draft = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: recovery)
                guard draft.id == id, draft.revision == revision else { throw AudioCommentStorageFailure.conflict }
                guard unlinkat(folder, filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
            }
            guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
        }
    }
    /// Explicit discard/settlement must not require space for a new checkpoint.
    /// A failed rename acknowledgement can leave either of these exact revisions;
    /// another window's changed bytes are never eligible for deletion.
    func discardReviewCopies(_ expected: [AudioCommentSavedDraft]) throws {
        guard let first = expected.first, expected.count <= 2,
              expected.allSatisfy({ $0.owner == owner && $0.id == first.id && $0.target == first.target }) else { throw AudioCommentStorageFailure.conflict }
        try locked { folder in
            let filename = name("review-", first.id)
            if let bytes = try read(filename, folder: folder) {
                let current = try AudioCommentSavedDraft(encoded: bytes, owner: owner, recovery: true)
                guard expected.contains(current) else { throw AudioCommentStorageFailure.conflict }
                guard unlinkat(folder, filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
            }
            guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
        }
    }
    func saveState(_ intent: AudioCommentSaveIntent) throws -> AudioCommentLocalSaveState {
        guard intent.next.owner == owner else { throw AudioCommentFailure.changed }
        try fault?(.beforeSaveState)
        return try locked { folder in
            if let data = try read(name("save-", intent.id), folder: folder) {
                let stored = try AudioCommentSaveIntent(encoded: data, owner: owner)
                // Durability belongs to the exact authorization, including a
                // chosen copy's IDs/base/reviews/provenance and discard phase.
                guard stored == intent else { throw AudioCommentStorageFailure.conflict }
                guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
                return .prepared
            }
            if let data = try read(name("draft-", intent.next.id), folder: folder), try AudioCommentSavedDraft(encoded: data, owner: owner) == intent.next {
                for ref in intent.reviews {
                    if let bytes = try read(name("review-", ref.id), folder: folder) {
                        let copy = try AudioCommentSavedDraft(encoded: bytes, owner: owner, recovery: true)
                        guard copy.target != intent.next.target || copy.revision != ref.revision else { throw AudioCommentStorageFailure.unreadable }
                    }
                }
                if let ref = intent.stage, let bytes = try read(ref.filename, folder: folder), ref.matches(bytes) { throw AudioCommentStorageFailure.unconfirmedSave }
                guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
                return .settled
            }
            return .unprepared
        }
    }

    func saves() throws -> [AudioCommentSaveIntent] {
        try locked { folder in try names(folder: folder).filter { $0.hasPrefix("save-") }.map { filename in
            guard let bytes = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
            let intent = try AudioCommentSaveIntent(encoded: bytes, owner: owner)
            guard filename == name("save-", intent.id) else { throw AudioCommentStorageFailure.unreadable }
            return intent
        } }
    }
    private func records(folder: Int32) throws -> (drafts: [AudioCommentSavedDraft], reviews: [AudioCommentSavedDraft], saves: [AudioCommentSaveIntent]) {
        var drafts: [AudioCommentSavedDraft] = [], reviews: [AudioCommentSavedDraft] = [], saves: [AudioCommentSaveIntent] = []
        for filename in try names(folder: folder) {
            if filename.hasPrefix("draft-") || filename.hasPrefix("review-") {
                guard let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
                let recovery = filename.hasPrefix("review-")
                let value = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: recovery)
                guard filename == name(recovery ? "review-" : "draft-", value.id) else { throw AudioCommentStorageFailure.unreadable }
                if recovery { reviews.append(value) } else { drafts.append(value) }
            } else if filename.hasPrefix("save-") {
                guard let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
                let value = try AudioCommentSaveIntent(encoded: data, owner: owner)
                guard filename == name("save-", value.id) else { throw AudioCommentStorageFailure.unreadable }
                saves.append(value)
            }
        }
        return (drafts, reviews, saves)
    }
    private func cleanupReviews(_ refs: [AudioCommentReviewReference], target: AudioCommentTarget, folder: Int32) throws {
        for id in Set(refs.map(\.id)) {
            let filename = name("review-", id)
            if let data = try read(filename, folder: folder) {
                let value = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: true)
                if value.target == target && refs.contains(.init(value)) {
                    guard unlinkat(folder, filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
                }
            }
        }
        guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
    }
    /// One locked snapshot prevents a recovery row being listed independently
    /// while another editor prepares its Save. Covered copies are safe cleanup:
    /// their exact content/provenance already has a durable primary recording.
    func catalog(target: AudioCommentTarget) throws -> AudioCommentDraftCatalog {
        try locked { folder in
            let all = try records(folder: folder)
            let saves = all.saves.filter { $0.next.target == target }
            let primary = all.drafts.filter { $0.target == target }
            var reviews: [AudioCommentSavedDraft] = []
            for review in all.reviews where review.target == target {
                let origin = review.origin ?? .init(review)
                if primary.contains(where: { $0.origin == origin && $0.sameContent(as: review) }) {
                    try cleanupReviews([.init(review)], target: target, folder: folder); continue
                }
                let protected = saves.contains { intent in
                    intent.reviews.contains(.init(review)) || (intent.next.origin == origin && intent.next.sameContent(as: review))
                }
                if !protected {
                    // Identical clones share one listing, but different edited
                    // content stays visible and requires a deliberate copy.
                    if let previous = reviews.first(where: { ($0.origin ?? .init($0)) == origin && $0.sameContent(as: review) }) {
                        if review.origin == nil, previous.origin != nil { reviews.removeAll { $0.id == previous.id }; reviews.append(review) }
                    } else { reviews.append(review) }
                }
            }
            let pendingIDs = Set(saves.map { $0.next.id })
            return .init(drafts: primary.filter { !pendingIDs.contains($0.id) }, reviews: reviews, saves: saves)
        }
    }
    /// Cancellation is first persisted under the same operation. A stale Finish
    /// can never switch a durable discard back to saving after relaunch.
    func discardSave(_ requested: AudioCommentSaveIntent) throws {
        guard requested.next.owner == owner else { throw AudioCommentFailure.changed }
        try withLock { folder, lock in
            let journal = name("save-", requested.id)
            guard let bytes = try read(journal, folder: folder) else { return }
            var current = try AudioCommentSaveIntent(encoded: bytes, owner: owner)
            guard current.sameAuthorization(as: requested) else { throw AudioCommentStorageFailure.conflict }
            if let data = try read(name("draft-", current.next.id), folder: folder), try AudioCommentSavedDraft(encoded: data, owner: owner) == current.next {
                throw AudioCommentStorageFailure.alreadySaved
            }
            do {
                if current.phase == .saving {
                    current = try current.markingDiscard()
                    let data = try current.encoded(); try admit(data, replacing: journal, folder: folder); try write(data, name: journal, folder: folder)
                    try fault?(.afterDiscardJournal)
                }
                // Rotate before deleting anything. A stale in-memory departure
                // may retain audio, but cannot recreate this discarded operation.
                try writeDepartureFence(UUID(), lock: lock)
                try cleanupReviews(current.reviews, target: current.next.target, folder: folder)
                guard unlinkat(folder, journal, 0) == 0, fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
            } catch { throw AudioCommentStorageFailure.discardPending }
        }
    }

    /// Discard only an expired editor's review. No new payload/journal is
    /// admitted, so this works at the entry/byte quota. One lock validates the
    /// missing authorization, protects claims belonging to other pending Saves,
    /// revokes stale automatic checkpoints and removes only exact review refs.
    func discardExpiredReview(_ requested: AudioCommentSaveIntent) throws {
        guard requested.next.owner == owner, requested.phase == .saving else { throw AudioCommentFailure.changed }
        try withLock { folder, lock in
            let all = try records(folder: folder)
            if let current = all.saves.first(where: { $0.sameAuthorization(as: requested) }) {
                throw current.phase == .discarding ? AudioCommentStorageFailure.discardPending : .conflict
            }
            guard !all.drafts.contains(requested.next) else { throw AudioCommentStorageFailure.alreadySaved }
            let removable = requested.reviews.filter { ref in
                !all.saves.contains { $0.reviews.contains(ref) || $0.next.origin == ref }
            }
            try writeDepartureFence(UUID(), lock: lock)
            try cleanupReviews(removable, target: requested.next.target, folder: folder)
            try fault?(.afterExpiredReviewDiscard)
        }
    }

    /// Journal first, then the exact optimistic draft, then recovery removals,
    /// then the journal removal. Every uncertain retry keeps the original IDs.
    /// Keep an already-authorized Save across process loss without completing it,
    /// creating a draft, clearing a review or publishing anything.
    func prepareSave(_ intent: AudioCommentSaveIntent, replacing old: AudioCommentSaveIntent? = nil, fence: UUID? = nil, existingOnly: Bool = false) throws {
        _ = try writeSave(intent, replacing: old, existingOnly: existingOnly, checkpointOnly: true, fence: fence)
    }
    @discardableResult func commitSave(_ intent: AudioCommentSaveIntent, replacing old: AudioCommentSaveIntent? = nil, existingOnly: Bool = false) throws -> AudioCommentSavedDraft {
        try writeSave(intent, replacing: old, existingOnly: existingOnly, checkpointOnly: false, fence: nil)
    }
    private func writeSave(_ intent: AudioCommentSaveIntent, replacing old: AudioCommentSaveIntent?, existingOnly: Bool, checkpointOnly: Bool, fence: UUID?) throws -> AudioCommentSavedDraft {
        guard intent.next.owner == owner else { throw AudioCommentFailure.changed }
        return try withLock { folder, lock in
            let journal = name("save-", intent.id), destination = name("draft-", intent.next.id)
            let own = try read(journal, folder: folder).map { try AudioCommentSaveIntent(encoded: $0, owner: owner) }
            guard intent.phase == .saving, own?.phase != .discarding else { throw AudioCommentStorageFailure.discardPending }
            let all = try records(folder: folder)
            if let stage = intent.stage {
                for filename in try names(folder: folder).filter({ $0.hasPrefix(".write-") }) {
                    guard let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
                    if let staged = try? AudioCommentSaveIntent(encoded: data, owner: owner), staged.stage == stage {
                        guard staged == intent else { throw AudioCommentStorageFailure.stageNeedsRecovery }
                    }
                }
            }
            if let stage = intent.stage, let other = all.saves.first(where: { $0.id != intent.id && $0.stage == stage }) {
                guard other.phase == .saving && other.next.sameContent(as: intent.next) else { throw AudioCommentStorageFailure.reviewClaimed }
                throw AudioCommentSaveRedirect(intent: other)
            }
            if let other = all.saves.first(where: { $0.id != intent.id && $0.next.id == intent.next.id }) {
                if other.phase == .saving && other.next.sameContent(as: intent.next) { throw AudioCommentSaveRedirect(intent: other) }
                throw AudioCommentStorageFailure.reviewClaimed
            }
            if let origin = intent.next.origin {
                let claimed = all.drafts.filter { $0.target == intent.next.target && $0.origin == origin }
                if let winner = claimed.first(where: { $0.id != intent.next.id }) {
                    guard winner.sameContent(as: intent.next) else { throw AudioCommentStorageFailure.reviewClaimed }
                    if !checkpointOnly { try cleanupReviews(intent.reviews, target: intent.next.target, folder: folder) }
                    return winner
                }
                if let other = all.saves.first(where: { $0.id != intent.id && $0.next.target == intent.next.target && ($0.next.origin == origin || $0.reviews.contains(origin)) }) {
                    guard other.phase == .saving && other.next.sameContent(as: intent.next) else { throw AudioCommentStorageFailure.reviewClaimed }
                    throw AudioCommentSaveRedirect(intent: other)
                }
                if own == nil && !claimed.contains(where: { $0.id == intent.next.id }) {
                    guard let root = all.reviews.first(where: { $0.id == origin.id && $0.revision == origin.revision && $0.target == intent.next.target }) else { throw AudioCommentStorageFailure.reviewClaimed }
                    _ = root
                }
            }
            func currentDraft(_ id: UUID) throws -> AudioCommentSavedDraft? {
                try read(name("draft-", id), folder: folder).map { try AudioCommentSavedDraft(encoded: $0, owner: owner) }
            }
            func conflicted(_ request: AudioCommentSaveIntent) throws -> Bool {
                if let current = try currentDraft(request.next.id) {
                    return current != request.next && (request.base == nil || current.revision != request.base || current.target != request.next.target)
                }
                return request.base != nil
            }
            let bytes = try intent.encoded()
            var preparedNow = false
            if let existing = try read(journal, folder: folder) {
                let prepared = try AudioCommentSaveIntent(encoded: existing, owner: owner)
                if prepared != intent {
                    guard let old, prepared == old, old.id == intent.id, old.next.owner == intent.next.owner,
                          old.next.target == intent.next.target, old.next.caption.utf8.elementsEqual(intent.next.caption.utf8), old.next.clip.data == intent.next.clip.data,
                          old.reviews == intent.reviews, old.stage == intent.stage, intent.base == nil, intent.next.id != old.next.id, try conflicted(old) else { throw AudioCommentStorageFailure.conflict }
                    if checkpointOnly { guard let fence, try readDepartureFence(lock) == fence else { throw AudioCommentStorageFailure.conflict } }
                    try admit(bytes, replacing: journal, folder: folder); try write(bytes, name: journal, folder: folder); preparedNow = true
                }
            } else {
                // A retry after the final journal unlink need not recreate work.
                if try currentDraft(intent.next.id) == intent.next {
                    let hasOldCopy = try intent.reviews.contains { ref in
                        guard let data = try read(name("review-", ref.id), folder: folder) else { return false }
                        let copy = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: true)
                        return copy.target == intent.next.target && copy.revision == ref.revision
                    }
                    let hasOldStage: Bool
                    if let ref = intent.stage, let data = try read(ref.filename, folder: folder) { hasOldStage = ref.matches(data) } else { hasOldStage = false }
                    if !hasOldCopy && !hasOldStage { guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }; return intent.next }
                }
                guard !existingOnly, old == nil else { throw AudioCommentStorageFailure.conflict }
                if let ref = intent.stage {
                    guard let data = try read(ref.filename, folder: folder), ref.matches(data),
                          let source = try? AudioCommentSavedDraft(encoded: data, owner: owner, recovery: ref.kind == .review),
                          source.sameContent(as: intent.next), source.id != intent.next.id, source.revision != intent.next.revision else { throw AudioCommentStorageFailure.reviewClaimed }
                }
                if checkpointOnly { guard let fence, try readDepartureFence(lock) == fence else { throw AudioCommentStorageFailure.conflict } }
                try admit(bytes, replacing: journal, folder: folder); try write(bytes, name: journal, folder: folder); preparedNow = true
            }
            if checkpointOnly {
                guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
                if preparedNow { try fault?(.afterSaveJournal) }
                return intent.next // Private helper only; prepareSave discards this value.
            }
            // From here quota/IO failure is an unconfirmed durable Save, not a
            // pre-write failure that authorizes minting a new draft identity.
            do {
                if preparedNow { try fault?(.afterSaveJournal) }
                let current = try currentDraft(intent.next.id)
                if current != intent.next {
                    if let current {
                        guard current.target == intent.next.target, current.revision == intent.base, current.revision != intent.next.revision else { throw AudioCommentStorageFailure.conflict }
                    } else if intent.base != nil { throw AudioCommentStorageFailure.conflict }
                    let payload = try intent.next.encoded(); try admit(payload, replacing: destination, folder: folder); try write(payload, name: destination, folder: folder)
                    try fault?(.afterDraftCommit)
                }
                // A different revision is another review, not eligible cleanup.
                for id in Set(intent.reviews.map(\.id)) {
                    let filename = name("review-", id)
                    if let data = try read(filename, folder: folder) {
                        let copy = try AudioCommentSavedDraft(encoded: data, owner: owner, recovery: true)
                        if copy.target == intent.next.target && intent.reviews.contains(.init(copy)) {
                            guard unlinkat(folder, filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
                        }
                    }
                }
                if let ref = intent.stage, let data = try read(ref.filename, folder: folder), ref.matches(data) {
                    guard unlinkat(folder, ref.filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
                }
                if intent.stage != nil { try fault?(.afterStageCleanup) }
                // Recovery removals must survive a crash before the journal can
                // disappear; otherwise the same review could be saved twice.
                guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
                // The draft and removals are now durable. Failed bookkeeping
                // cleanup may leave/replay the journal, but cannot lose work or
                // justify reporting the actual Save as uncommitted.
                if unlinkat(folder, journal, 0) == 0 { _ = fsync(folder) }
            } catch let error as AudioCommentStorageFailure where error == .conflict { throw error }
            catch { throw AudioCommentStorageFailure.unconfirmedSave }
            return intent.next
        }
    }

    private func cloudAccount() throws -> UUID {
        guard let account = UUID(uuidString: owner.account), account != AudioCommentTarget.zero else { throw AudioCommentFailure.changed }; return account
    }
    func pending() throws -> [AudioCommentPending] {
        let account = try cloudAccount()
        return try locked { folder in try names(folder: folder).filter { $0.hasPrefix("pending-") }.map { filename in
            guard let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
            let pending = try AudioCommentPending(encoded: data, account: account)
            guard filename == name("pending-", pending.publication.operation) else { throw AudioCommentStorageFailure.unreadable }; return pending
        } }
    }
    func store(_ pending: AudioCommentPending) throws {
        guard pending.publication.account == (try cloudAccount()) else { throw AudioCommentFailure.changed }
        try locked { folder in
            let filename = name("pending-", pending.publication.operation)
            if let data = try read(filename, folder: folder) {
                let current = try AudioCommentPending(encoded: data, account: pending.publication.account)
                guard current.publication.sameIntent(as: pending.publication), current.clip.data == pending.clip.data else { throw AudioCommentStorageFailure.conflict }
                guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }; return
            }
            let data = try pending.encoded(); try admit(data, replacing: filename, folder: folder); try write(data, name: filename, folder: folder)
        }
    }
    /// Caller must first validate the authenticated server receipt. No automatic
    /// deletion on logout, Cancel, a timeout, or an echoed request is permitted.
    func removeSettled(_ publication: AudioCommentPublication) throws {
        guard publication.account == (try cloudAccount()) else { throw AudioCommentFailure.changed }
        try locked { folder in
            let filename = name("pending-", publication.operation)
            if let data = try read(filename, folder: folder) {
                let pending = try AudioCommentPending(encoded: data, account: publication.account)
                guard pending.publication.sameIntent(as: publication) else { throw AudioCommentStorageFailure.conflict }
                guard unlinkat(folder, filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
            }
            guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
        }
    }
}


/// Serial disk work stays off the UI actor. UI callers must still revalidate their
/// live workspace/task binding after every await before displaying or publishing.
actor AudioCommentDraftStorage {
    nonisolated let owner: AudioCommentOwner
    private let vault: AudioCommentVault
    init(applicationSupport: URL, owner: AudioCommentOwner) { self.owner = owner; vault = .init(applicationSupport: applicationSupport, owner: owner) }
    init(vault: AudioCommentVault) { self.vault = vault; owner = vault.owner }
    func drafts() throws -> [AudioCommentSavedDraft] { try vault.drafts() }
    func reviews() throws -> [AudioCommentSavedDraft] { try vault.drafts(recovery: true) }
    func saves() throws -> [AudioCommentSaveIntent] { try vault.saves() }
    func saveState(_ intent: AudioCommentSaveIntent) throws -> AudioCommentLocalSaveState { try vault.saveState(intent) }
    func departureFence() throws -> UUID { try vault.departureFence() }
    func prepareSave(_ intent: AudioCommentSaveIntent, replacing old: AudioCommentSaveIntent? = nil, fence: UUID? = nil, existingOnly: Bool = false) throws { try vault.prepareSave(intent, replacing: old, fence: fence, existingOnly: existingOnly) }
    @discardableResult func commitSave(_ intent: AudioCommentSaveIntent, replacing old: AudioCommentSaveIntent? = nil, existingOnly: Bool = false) throws -> AudioCommentSavedDraft { try vault.commitSave(intent, replacing: old, existingOnly: existingOnly) }
    func catalog(target: AudioCommentTarget) throws -> AudioCommentDraftCatalog { try vault.catalog(target: target) }
    func discardSave(_ intent: AudioCommentSaveIntent) throws { try vault.discardSave(intent) }
    func discardExpiredReview(_ intent: AudioCommentSaveIntent) throws { try vault.discardExpiredReview(intent) }
    func discardReviewCopies(_ expected: [AudioCommentSavedDraft]) throws { try vault.discardReviewCopies(expected) }
    func checkpoint(_ draft: AudioCommentSavedDraft, replacing revision: UUID? = nil) throws { try vault.save(draft, replacing: revision, recovery: true) }
    func discardReview(_ id: UUID, revision: UUID) throws { try vault.discardDraft(id, revision: revision, recovery: true) }
    func save(_ draft: AudioCommentSavedDraft, replacing revision: UUID? = nil) throws { try vault.save(draft, replacing: revision) }
    func discardDraft(_ id: UUID, revision: UUID) throws { try vault.discardDraft(id, revision: revision) }
    func pending() throws -> [AudioCommentPending] { try vault.pending() }
    func store(_ pending: AudioCommentPending) throws { try vault.store(pending) }
    func removeSettled(_ publication: AudioCommentPublication) throws { try vault.removeSettled(publication) }
    func interruptedWrites() throws -> [AudioCommentInterruptedWrite] { try vault.interruptedWrites() }
    func interruptedCatalog() throws -> AudioCommentInterruptedCatalog { try vault.interruptedCatalog() }
    func recover(_ candidate: AudioCommentInterruptedWrite, replacing revision: UUID? = nil) throws { try vault.recover(candidate, replacing: revision) }
}
