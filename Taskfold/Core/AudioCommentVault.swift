import Foundation
import CryptoKit
import Darwin

struct AudioCommentStorageFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static let unreadable = Self(message: "Audio drafts could not be read safely. Your saved recordings have not been replaced.")
    static let conflict = Self(message: "This audio draft changed in another window. Reload it before saving.")
    static let busy = Self(message: "Audio drafts are being saved. Try again in a moment.")
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
    init(owner: AudioCommentOwner, target: AudioCommentTarget, caption: String, clip: AudioCommentClip, id: UUID = UUID(), revision: UUID = UUID()) throws {
        guard id != AudioCommentTarget.zero, revision != AudioCommentTarget.zero else { throw AudioCommentFailure.changed }
        try AudioCommentPublication.validateCaption(caption)
        self.owner = owner; self.target = target; self.caption = caption; self.clip = clip; self.id = id; self.revision = revision
    }
    func replacing(caption: String, clip: AudioCommentClip) throws -> Self {
        if self.caption.utf8.elementsEqual(caption.utf8), self.clip.data == clip.data { return self }
        return try .init(owner: owner, target: target, caption: caption, clip: clip, id: id)
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.owner == rhs.owner && lhs.target == rhs.target && lhs.caption.utf8.elementsEqual(rhs.caption.utf8) && lhs.clip.data == rhs.clip.data
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try PropertyListSerialization.data(fromPropertyList: [
            "format": "taskfold-audio-review-v1", "account": owner.account,
            "id": id.uuidString.lowercased(), "revision": revision.uuidString.lowercased(),
            "target": try encoder.encode(target), "caption": caption,
            "descriptor": try encoder.encode(clip.descriptor), "audio": clip.data
        ], format: .binary, options: 0)
    }
    init(encoded data: Data, owner: AudioCommentOwner) throws {
        guard !data.isEmpty, data.count <= AudioCommentVault.maximumFileBytes else { throw AudioCommentStorageFailure.unreadable }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let fields = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any], format == .binary,
              Set(fields.keys) == ["format", "account", "id", "revision", "target", "caption", "descriptor", "audio"],
              fields["format"] as? String == "taskfold-audio-review-v1", let account = fields["account"] as? String,
              account.utf8.elementsEqual(owner.account.utf8), let idText = fields["id"] as? String, let id = UUID(uuidString: idText),
              let revisionText = fields["revision"] as? String, let revision = UUID(uuidString: revisionText),
              let targetData = fields["target"] as? Data, targetData.count <= 4096,
              let descriptorData = fields["descriptor"] as? Data, descriptorData.count <= 4096,
              let caption = fields["caption"] as? String, let audio = fields["audio"] as? Data else { throw AudioCommentStorageFailure.unreadable }
        let descriptor = try JSONDecoder().decode(AudioCommentDescriptor.self, from: descriptorData)
        let clip = try AudioCommentClip(restoring: audio, descriptor: descriptor)
        try self.init(owner: owner, target: JSONDecoder().decode(AudioCommentTarget.self, from: targetData), caption: caption, clip: clip, id: id, revision: revision)
    }
}


struct AudioCommentInterruptedWrite: Sendable {
    enum Payload: Sendable { case draft(AudioCommentSavedDraft), pending(AudioCommentPending) }
    let id: UUID
    let payload: Payload
    fileprivate let bytes: Data
}

/// An account-private, process-locked store. No App Group or portable snapshot refs.
/// All payload IO uses the opened directory; symlinks and hard-linked files refuse.
struct AudioCommentVault: Sendable {
    static let maximumFileBytes = 8_100_000
    static let maximumEntries = 20
    static let maximumTotalBytes = 50_000_000
    enum Checkpoint: Sendable { case beforeRename, afterRename }
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
    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        let parent = Darwin.open(applicationSupport.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AudioCommentStorageFailure.unreadable }; defer { Darwin.close(parent) }
        let root = try childDirectory("AudioCommentsPrivate", parent: parent); defer { Darwin.close(root) }
        let folder = try childDirectory(owner.directoryName, parent: root); defer { Darwin.close(folder) }
        let lock = openat(folder, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw AudioCommentStorageFailure.unreadable }; defer { Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), fchmod(lock, 0o600) == 0 else { throw AudioCommentStorageFailure.unreadable }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.busy }; defer { _ = flock(lock, LOCK_UN) }
        return try body(folder)
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
            let committed = ["draft-", "pending-"].contains(where: { value.hasPrefix($0) }) && value.hasSuffix(".bin") && UUID(uuidString: String(value.dropFirst(value.hasPrefix("draft-") ? 6 : 8).dropLast(4))) != nil
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
        try locked { folder in try names(folder: folder).filter { $0.hasPrefix(".write-") }.map { filename in
            guard let id = UUID(uuidString: String(filename.dropFirst(7))), let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
            let payload: AudioCommentInterruptedWrite.Payload
            if let draft = try? AudioCommentSavedDraft(encoded: data, owner: owner) { payload = .draft(draft) }
            else { payload = .pending(try AudioCommentPending(encoded: data, account: cloudAccount())) }
            return .init(id: id, payload: payload, bytes: data)
        } }
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
            case .draft(let draft):
                guard draft.owner == owner, try AudioCommentSavedDraft(encoded: data, owner: owner) == draft else { throw AudioCommentStorageFailure.conflict }
                destination = name("draft-", draft.id)
                if let bytes = try read(destination, folder: folder) {
                    let current = try AudioCommentSavedDraft(encoded: bytes, owner: owner)
                    identical = current == draft
                    guard identical || current.id == draft.id && current.target == draft.target && current.revision == revision && current.revision != draft.revision else { throw AudioCommentStorageFailure.conflict }
                } else if revision != nil { throw AudioCommentStorageFailure.conflict }
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

    func drafts() throws -> [AudioCommentSavedDraft] {
        try locked { folder in try names(folder: folder).filter { $0.hasPrefix("draft-") }.map { filename in
            guard let data = try read(filename, folder: folder) else { throw AudioCommentStorageFailure.unreadable }
            let draft = try AudioCommentSavedDraft(encoded: data, owner: owner)
            guard filename == name("draft-", draft.id) else { throw AudioCommentStorageFailure.unreadable }; return draft
        } }
    }
    func save(_ draft: AudioCommentSavedDraft, replacing revision: UUID? = nil) throws {
        guard draft.owner == owner else { throw AudioCommentFailure.changed }
        try locked { folder in
            let filename = name("draft-", draft.id)
            if let data = try read(filename, folder: folder) {
                let current = try AudioCommentSavedDraft(encoded: data, owner: owner)
                if current == draft { guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }; return }
                guard current.id == draft.id, current.target == draft.target, current.revision == revision, current.revision != draft.revision else { throw AudioCommentStorageFailure.conflict }
            } else if revision != nil { throw AudioCommentStorageFailure.conflict }
            let data = try draft.encoded(); try admit(data, replacing: filename, folder: folder); try write(data, name: filename, folder: folder)
        }
    }
    func discardDraft(_ id: UUID, revision: UUID) throws {
        try locked { folder in
            let filename = name("draft-", id)
            if let data = try read(filename, folder: folder) {
                let draft = try AudioCommentSavedDraft(encoded: data, owner: owner)
                guard draft.id == id, draft.revision == revision else { throw AudioCommentStorageFailure.conflict }
                guard unlinkat(folder, filename, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }
            }
            guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
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
    private let vault: AudioCommentVault
    init(applicationSupport: URL, owner: AudioCommentOwner) { vault = .init(applicationSupport: applicationSupport, owner: owner) }
    init(vault: AudioCommentVault) { self.vault = vault }
    func drafts() throws -> [AudioCommentSavedDraft] { try vault.drafts() }
    func save(_ draft: AudioCommentSavedDraft, replacing revision: UUID? = nil) throws { try vault.save(draft, replacing: revision) }
    func discardDraft(_ id: UUID, revision: UUID) throws { try vault.discardDraft(id, revision: revision) }
    func pending() throws -> [AudioCommentPending] { try vault.pending() }
    func store(_ pending: AudioCommentPending) throws { try vault.store(pending) }
    func removeSettled(_ publication: AudioCommentPublication) throws { try vault.removeSettled(publication) }
    func interruptedWrites() throws -> [AudioCommentInterruptedWrite] { try vault.interruptedWrites() }
    func recover(_ candidate: AudioCommentInterruptedWrite, replacing revision: UUID? = nil) throws { try vault.recover(candidate, replacing: revision) }
}
