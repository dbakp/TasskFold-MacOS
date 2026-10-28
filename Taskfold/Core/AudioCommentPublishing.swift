import Foundation
import CryptoKit
import Observation
import Darwin

struct AudioCommentPublishedReceipt: Sendable {
    let publication: AudioCommentPublication
    let record: Record
    init(record: Record, publication: AudioCommentPublication) throws {
        guard Set(record.fields.keys) == ["protocol", "account", "operation_id", "comment_id", "asset_id", "author_id", "target", "caption", "audio", "state", "reserved_at", "expires_at", "published_at"], record["protocol"] == .number(1), record.string("state") == "published", record.string("author_id") == publication.account.uuidString.lowercased() else { throw AudioCommentFailure.invalid }
        var intent = record.fields
        for field in ["protocol", "author_id", "state", "reserved_at", "expires_at", "published_at"] { intent.removeValue(forKey: field) }
        intent["version"] = .number(1)
        guard try AudioCommentPublication(record: Record(intent)).sameIntent(as: publication) else { throw AudioCommentFailure.changed }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let dates = try ["reserved_at", "expires_at", "published_at"].map { name -> Date in
            guard case .string(let value) = record[name], value.utf8.count <= 40, let date = formatter.date(from: value) ?? plain.date(from: value) else { throw AudioCommentFailure.invalid }; return date
        }
        guard dates[1] >= dates[0], dates[2] >= dates[0], dates[2] <= dates[1] else { throw AudioCommentFailure.invalid }
        self.publication = publication; self.record = record
    }
}

/// An exact authenticated terminal result: the original operation cannot resume.
/// It does not claim that the comment was never visible or that Storage cleanup
/// has finished. Timeouts, absence and permission failures are not this proof.
struct AudioCommentPublicationClosed: Error, LocalizedError, Sendable {
    let publication: AudioCommentPublication
    let record: Record
    var errorDescription: String? { "The original publication is closed. Your private recording is preserved." }
    init(record: Record, publication: AudioCommentPublication) throws {
        guard Set(record.fields.keys) == ["protocol", "intent", "state"],
              record["protocol"] == .number(1), record["state"] == .string("closed"),
              case .object(let fields) = record["intent"],
              try AudioCommentPublication(record:Record(fields)).sameIntent(as:publication) else { throw AudioCommentFailure.changed }
        self.publication=publication;self.record=record
    }
}

struct AudioCommentPublicationJournal: Sendable {
    let origin: String
    let source: UUID
    let revision: UUID
    let publication: AudioCommentPublication
    let clip: AudioCommentClip?
    let receipt: AudioCommentPublishedReceipt?
    let closedReceipt: AudioCommentPublicationClosed?
    var isPending: Bool {receipt == nil && closedReceipt == nil}
    var isResolved: Bool {!isPending}
    static func canonicalOrigin(_ input: String) throws -> String {
        guard input.utf8.count <= 2048, var url = URLComponents(string: input), url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw AudioCommentFailure.changed }
        url.host = host.lowercased(); url.path = ""; if url.port == 443 { url.port = nil }
        guard let result = url.string else { throw AudioCommentFailure.changed }; return result
    }
    init(source: AudioCommentSavedDraft, origin: String) throws {
        guard let account = UUID(uuidString: source.owner.account), account != AudioCommentTarget.zero else { throw AudioCommentFailure.changed }
        self.origin = try Self.canonicalOrigin(origin); self.source = source.id; revision = source.revision
        publication = try .init(account: account, target: source.target, caption: source.caption, descriptor: source.clip.descriptor)
        clip = source.clip; receipt = nil; closedReceipt = nil
    }
    private init(_ original: Self, receipt: AudioCommentPublishedReceipt, retainingAudio: Bool) throws {
        guard original.closedReceipt == nil,receipt.publication.sameIntent(as: original.publication) else { throw AudioCommentFailure.changed }
        origin = original.origin; source = original.source; revision = original.revision; publication = original.publication; clip = retainingAudio ? original.clip : nil; self.receipt = receipt; closedReceipt = nil
    }
    private init(_ original: Self, closed: AudioCommentPublicationClosed, retainingAudio: Bool) throws {
        guard original.receipt == nil,closed.publication.sameIntent(as:original.publication) else {throw AudioCommentStorageFailure.conflict}
        origin=original.origin;source=original.source;revision=original.revision;publication=original.publication
        clip=retainingAudio ? original.clip:nil;receipt=nil;closedReceipt=closed
    }
    func closed(_ proof: AudioCommentPublicationClosed) throws -> Self {try .init(self,closed:proof,retainingAudio:true)}
    func releasingResolvedAudio() throws -> Self {
        if let closedReceipt {return try .init(self,closed:closedReceipt,retainingAudio:false)}
        return try releasingConfirmedAudio()
    }
    /// A private recovery copy uses the original asset/operation as its stable
    /// local ID/revision. Reopening it must reconcile, not mint another comment.
    func represents(_ draft: AudioCommentSavedDraft) -> Bool {
        source == draft.id && revision == draft.revision || publication.asset == draft.id && publication.operation == draft.revision
    }
    func confirmed(_ receipt: AudioCommentPublishedReceipt, retainingAudio: Bool = false) throws -> Self { try .init(self, receipt: receipt, retainingAudio: retainingAudio) }
    func releasingConfirmedAudio() throws -> Self { guard let receipt else { throw AudioCommentStorageFailure.conflict }; return try .init(self, receipt: receipt, retainingAudio: false) }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var fields: [String:Any] = ["format": closedReceipt != nil ? "taskfold-audio-publication-v3" : (receipt != nil && clip != nil ? "taskfold-audio-publication-v2" : "taskfold-audio-publication-v1"), "origin": origin, "source": source.uuidString.lowercased(), "revision": revision.uuidString.lowercased(), "intent": try encoder.encode(publication), "audio": clip?.data ?? Data(), "receipt": try receipt.map { try encoder.encode($0.record) } ?? Data()]
        if let closedReceipt {fields["closed"] = try encoder.encode(closedReceipt.record)}
        return try PropertyListSerialization.data(fromPropertyList:fields,format:.binary,options:0)
    }
    init(encoded data: Data, account: UUID, origin: String) throws {
        guard data.count <= 8_100_000 else { throw AudioCommentFailure.invalid }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let fields = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any], format == .binary,
              Set(fields.keys) == (fields["format"] as? String == "taskfold-audio-publication-v3" ? ["format", "origin", "source", "revision", "intent", "audio", "receipt", "closed"] : ["format", "origin", "source", "revision", "intent", "audio", "receipt"]),
              ["taskfold-audio-publication-v1", "taskfold-audio-publication-v2", "taskfold-audio-publication-v3"].contains(fields["format"] as? String ?? ""),
              fields["origin"] as? String == (try Self.canonicalOrigin(origin)), let source = (fields["source"] as? String).flatMap(UUID.init(uuidString:)), source != AudioCommentTarget.zero,
              let revision = (fields["revision"] as? String).flatMap(UUID.init(uuidString:)), revision != AudioCommentTarget.zero,
              let intent = fields["intent"] as? Data, intent.count <= 32_000, let audio = fields["audio"] as? Data, let receipt = fields["receipt"] as? Data, receipt.count <= 64_000 else { throw AudioCommentFailure.invalid }
        self.origin = try Self.canonicalOrigin(origin); self.source = source; self.revision = revision
        publication = try JSONDecoder().decode(AudioCommentPublication.self, from: intent)
        guard publication.account == account else { throw AudioCommentFailure.changed }
        if fields["format"] as? String == "taskfold-audio-publication-v3" {
            guard receipt.isEmpty,let proof=fields["closed"] as? Data,!proof.isEmpty,proof.count<=32000 else {throw AudioCommentFailure.invalid}
            closedReceipt=try .init(record:JSONDecoder().decode(Record.self,from:proof),publication:publication)
            self.receipt=nil;clip=audio.isEmpty ? nil:try AudioCommentClip(restoring:audio,descriptor:publication.descriptor)
        } else if receipt.isEmpty {
            closedReceipt=nil
            guard fields["format"] as? String == "taskfold-audio-publication-v1" else { throw AudioCommentFailure.invalid }
            clip = try AudioCommentClip(restoring: audio, descriptor: publication.descriptor); self.receipt = nil
        } else {
            closedReceipt=nil
            let retained = fields["format"] as? String == "taskfold-audio-publication-v2"
            guard retained != audio.isEmpty else { throw AudioCommentFailure.invalid }
            clip = retained ? try AudioCommentClip(restoring: audio, descriptor: publication.descriptor) : nil
            self.receipt = try .init(record: JSONDecoder().decode(Record.self, from: receipt), publication: publication)
        }
    }
}

/// Separate device-private namespace. A successful server receipt replaces the
/// journal atomically; its compact identity proof survives while local audio is
/// released from this journal. The saved recording itself is never removed here.
struct AudioCommentPublicationDisk: Sendable {
    enum Checkpoint: Sendable { case beforeRename, afterRename }
    let root: URL
    let account: UUID
    let origin: String
    var fault: (@Sendable (Checkpoint) throws -> Void)?
    init(root: URL, account: UUID, origin: String) throws {
        guard account != AudioCommentTarget.zero else { throw AudioCommentFailure.changed }
        self.root = root; self.account = account; self.origin = try AudioCommentPublicationJournal.canonicalOrigin(origin)
    }
    private var namespace: String { SHA256.hash(data: Data((origin + "\n" + account.uuidString.lowercased()).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func locked<T>(_ work: (Int32) throws -> T) throws -> T {
        let base = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard base >= 0 else { throw AudioCommentStorageFailure.unreadable }; defer { Darwin.close(base) }
        var baseInfo = stat(); guard fstat(base, &baseInfo) == 0, baseInfo.st_uid == getuid() else { throw AudioCommentStorageFailure.unreadable }
        func child(_ name: String, _ parent: Int32) throws -> Int32 {
            let made = mkdirat(parent, name, 0o700) == 0; guard made || errno == EEXIST else { throw AudioCommentStorageFailure.unreadable }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard fd >= 0 else { throw AudioCommentStorageFailure.unreadable }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0, fsync(parent) == 0 else { Darwin.close(fd); throw AudioCommentStorageFailure.unreadable }; return fd
        }
        let parent = try child("AudioPublicationJournal", base); defer { Darwin.close(parent) }
        let folder = try child(namespace, parent); defer { Darwin.close(folder) }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = root.appendingPathComponent("AudioPublicationJournal").appendingPathComponent(namespace); try url.setResourceValues(values)
        let lock = openat(folder, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600); guard lock >= 0 else { throw AudioCommentStorageFailure.unreadable }; defer { Darwin.close(lock) }
        var info = stat(); guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, fchmod(lock, 0o600) == 0 else { throw AudioCommentStorageFailure.unreadable }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.busy }; defer { flock(lock, LOCK_UN) }
        let result = try work(folder); guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }; return result
    }
    private func names(_ folder: Int32) throws -> [String] {
        let fd = openat(folder, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard fd >= 0, let stream = fdopendir(fd) else { if fd >= 0 { Darwin.close(fd) }; throw AudioCommentStorageFailure.unreadable }; defer { closedir(stream) }
        var result: [String] = []; var total: Int64 = 0
        while true {
            errno = 0; guard let entry = readdir(stream) else { guard errno == 0 else { throw AudioCommentStorageFailure.unreadable }; break }
            let value = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if [".", "..", ".lock"].contains(value) { continue }
            let stage = value.hasPrefix(".write-") && UUID(uuidString: String(value.dropFirst(7))) != nil
            guard stage || value.hasSuffix(".bin") && UUID(uuidString: String(value.dropLast(4))) != nil else { throw AudioCommentStorageFailure.unreadable }
            var info = stat(); guard fstatat(folder, value, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0, info.st_size <= 8_100_000 else { throw AudioCommentStorageFailure.unreadable }
            if stage { guard unlinkat(folder, value, 0) == 0 else { throw AudioCommentStorageFailure.unreadable }; continue }
            total += info.st_size; guard total <= 50_000_000, result.count < 1000 else { throw AudioCommentStorageFailure.full }; result.append(value)
        }
        return result.sorted()
    }
    private func read(_ name: String, _ folder: Int32) throws -> AudioCommentPublicationJournal {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); guard fd >= 0 else { throw AudioCommentStorageFailure.unreadable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 8_100_000 else { throw AudioCommentStorageFailure.unreadable }
        let data = try file.read(upToCount: 8_100_001) ?? Data(); guard data.count == info.st_size else { throw AudioCommentStorageFailure.unreadable }
        let journal = try AudioCommentPublicationJournal(encoded: data, account: account, origin: origin)
        guard name == journal.publication.operation.uuidString.lowercased() + ".bin" else { throw AudioCommentStorageFailure.unreadable }; return journal
    }
    private func all(_ folder: Int32) throws -> [AudioCommentPublicationJournal] {
        let rows = try names(folder).map { try read($0, folder) }
        guard Set(rows.map { $0.source.uuidString + ":" + $0.revision.uuidString }).count == rows.count else { throw AudioCommentStorageFailure.unreadable }; return rows
    }
    private func write(_ journal: AudioCommentPublicationJournal, _ folder: Int32) throws {
        let data = try journal.encoded(), destination = journal.publication.operation.uuidString.lowercased() + ".bin"
        let existing = try all(folder), bytes = try existing.reduce(0) { $0 + ($1.publication.operation == journal.publication.operation ? 0 : try $1.encoded().count) }
        let otherPending = existing.filter { $0.isPending && $0.publication.operation != journal.publication.operation }.count
        let previous = try existing.first(where: { $0.publication.operation == journal.publication.operation })?.encoded().count ?? 0
        let reserved = (otherPending + (journal.isPending ? 1 : 0)) * 64_000
        // Reserve confirmation metadata before a send, and never let a full
        // pending quota prevent shrinking an already-confirmed local copy.
        guard data.count <= 8_100_000, bytes + data.count <= 50_000_000,
              data.count <= previous || bytes + data.count + reserved <= 50_000_000,
              existing.count < 1000 || previous > 0, journal.isResolved || otherPending < 20 else { throw AudioCommentStorageFailure.full }
        let stage = ".write-" + UUID().uuidString.lowercased(); let fd = openat(folder, stage, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600); guard fd >= 0 else { throw AudioCommentStorageFailure.unreadable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close(); _ = unlinkat(folder, stage, 0) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.appendingPathComponent("AudioPublicationJournal").appendingPathComponent(namespace).appendingPathComponent(stage).path)
        #endif
        try file.write(contentsOf: data); try file.synchronize(); try file.close(); try fault?(.beforeRename)
        guard renameat(folder, stage, folder, destination) == 0 else { throw AudioCommentStorageFailure.unreadable }
        try fault?(.afterRename); guard fsync(folder) == 0 else { throw AudioCommentStorageFailure.unreadable }
    }
    func journals() throws -> [AudioCommentPublicationJournal] { try locked { try all($0) } }
    func prepare(_ source: AudioCommentSavedDraft) throws -> AudioCommentPublicationJournal {
        guard source.owner.account == account.uuidString.lowercased() else { throw AudioCommentFailure.changed }
        return try locked { folder in
            let existing = try all(folder).filter { $0.source == source.id || $0.publication.asset == source.id }
            if let same = existing.first(where: { $0.represents(source) }) {
                guard same.publication.target == source.target, same.publication.caption.utf8.elementsEqual(source.caption.utf8), same.publication.descriptor == source.clip.descriptor else { throw AudioCommentStorageFailure.conflict }; return same
            }
            guard !existing.contains(where: { $0.isPending }) else { throw AudioCommentFailure(message: "An earlier version is still awaiting confirmation. Check it before publishing another version.") }
            let journal = try AudioCommentPublicationJournal(source: source, origin: origin); try write(journal, folder); return journal
        }
    }
    func confirm(_ expected: AudioCommentPublicationJournal, receipt: AudioCommentPublishedReceipt, retainingAudio: Bool = false) throws -> AudioCommentPublicationJournal {
        guard expected.origin == origin, expected.publication.account == account, receipt.publication.sameIntent(as: expected.publication) else { throw AudioCommentFailure.changed }
        return try locked { folder in
            let current = try read(expected.publication.operation.uuidString.lowercased() + ".bin", folder)
            guard current.source == expected.source, current.revision == expected.revision, current.publication.sameIntent(as: expected.publication) else { throw AudioCommentStorageFailure.conflict }
            if current.receipt != nil { return current }
            guard current.closedReceipt == nil else {throw AudioCommentStorageFailure.conflict}
            let confirmed = try current.confirmed(receipt, retainingAudio: retainingAudio); try write(confirmed, folder); return confirmed
        }
    }
    func settleClosed(_ expected:AudioCommentPublicationJournal,proof:AudioCommentPublicationClosed) throws -> AudioCommentPublicationJournal {
        guard expected.origin==origin,expected.publication.account==account,proof.publication.sameIntent(as:expected.publication) else {throw AudioCommentFailure.changed}
        return try locked {folder in
            let current=try read(expected.publication.operation.uuidString.lowercased()+".bin",folder)
            guard current.source==expected.source,current.revision==expected.revision,current.publication.sameIntent(as:expected.publication),current.receipt==nil else {throw AudioCommentStorageFailure.conflict}
            if let prior=current.closedReceipt {guard prior.record==proof.record else {throw AudioCommentStorageFailure.conflict};return current}
            let closed=try current.closed(proof);try write(closed,folder);return closed
        }
    }
    /// Exact proof stays durable after explicit removal of only its local media.
    func releaseResolvedAudio(_ expected:AudioCommentPublicationJournal) throws -> AudioCommentPublicationJournal {
        guard expected.origin==origin,expected.publication.account==account,expected.isResolved else {throw AudioCommentStorageFailure.conflict}
        return try locked {folder in
            let current=try read(expected.publication.operation.uuidString.lowercased()+".bin",folder)
            guard current.source==expected.source,current.revision==expected.revision,current.publication.sameIntent(as:expected.publication),
                  current.receipt?.record==expected.receipt?.record,current.closedReceipt?.record==expected.closedReceipt?.record,current.isResolved else {throw AudioCommentStorageFailure.conflict}
            if current.clip==nil {return current}
            let compact=try current.releasingResolvedAudio();try write(compact,folder);return compact
        }
    }
    /// Explicit local removal only after an exact persisted confirmation. Never
    /// use this for Cancel, logout, timeout, pending work or server removal.
    func releaseConfirmedAudio(_ expected: AudioCommentPublicationJournal) throws -> AudioCommentPublicationJournal {
        guard expected.origin == origin, expected.publication.account == account, let receipt = expected.receipt else { throw AudioCommentStorageFailure.conflict }
        return try locked { folder in
            let current = try read(expected.publication.operation.uuidString.lowercased() + ".bin", folder)
            guard current.source == expected.source, current.revision == expected.revision, current.publication.sameIntent(as: expected.publication), current.receipt?.record == receipt.record else { throw AudioCommentStorageFailure.conflict }
            if current.clip == nil { return current }
            let compact = try current.releasingConfirmedAudio(); try write(compact, folder); return compact
        }
    }
}

actor AudioCommentPublicationStorage {
    nonisolated let account: UUID
    nonisolated let origin: String
    private let disk: AudioCommentPublicationDisk
    init(disk: AudioCommentPublicationDisk) { self.disk = disk; account = disk.account; origin = disk.origin }
    func prepare(_ source: AudioCommentSavedDraft) throws -> AudioCommentPublicationJournal { try disk.prepare(source) }
    func journals() throws -> [AudioCommentPublicationJournal] { try disk.journals() }
    func confirm(_ journal: AudioCommentPublicationJournal, receipt: AudioCommentPublishedReceipt, retainingAudio: Bool = false) throws -> AudioCommentPublicationJournal { try disk.confirm(journal, receipt: receipt, retainingAudio: retainingAudio) }
    func releaseConfirmedAudio(_ journal: AudioCommentPublicationJournal) throws -> AudioCommentPublicationJournal { try disk.releaseConfirmedAudio(journal) }
    func settleClosed(_ journal:AudioCommentPublicationJournal,proof:AudioCommentPublicationClosed) throws -> AudioCommentPublicationJournal {try disk.settleClosed(journal,proof:proof)}
    func releaseResolvedAudio(_ journal:AudioCommentPublicationJournal) throws -> AudioCommentPublicationJournal {try disk.releaseResolvedAudio(journal)}
}

@MainActor protocol AudioCommentPublishingTransport: AnyObject {
    func publishAudio(_ pending: AudioCommentPending, origin: String, incarnation: UUID) async throws -> AudioCommentPublishedReceipt
}

/// Every send is explicit. Departure/cancellation leaves the durable operation
/// intact; a late response cannot update the active UI or another account.
@MainActor @Observable final class AudioCommentPublicationFlow {
    enum State { case ready, saving, sending, unconfirmed, published, closed }
    private(set) var state: State = .ready
    private(set) var journal: AudioCommentPublicationJournal?
    private let storage: AudioCommentPublicationStorage
    private let transport: any AudioCommentPublishingTransport
    private let current: @MainActor () -> Bool
    private let incarnation: UUID
    private let target: AudioCommentTarget
    private let retainAudioOnConfirmation: Bool
    private var attempt = UUID()
    var contextIsCurrent: Bool { current() }
    func invalidate() { attempt = UUID(); journal = nil; state = .ready }
    private func check(_ token: UUID) throws { guard token == attempt, current(), !Task.isCancelled else { throw CancellationError() } }
    init(storage: AudioCommentPublicationStorage, transport: any AudioCommentPublishingTransport, incarnation: UUID, target: AudioCommentTarget, retainAudioOnConfirmation: Bool = false, isCurrent: @escaping @MainActor () -> Bool) { self.storage = storage; self.transport = transport; self.incarnation = incarnation; self.target = target; self.retainAudioOnConfirmation = retainAudioOnConfirmation; current = isCurrent }
    /// Local review only: reopening a recording never starts a network request.
    func restore(_ source: AudioCommentSavedDraft) async throws {
        guard source.target == target, source.owner.account == storage.account.uuidString.lowercased(), current(), !Task.isCancelled, state != .saving, state != .sending else { throw CancellationError() }
        let token = attempt; journal = nil; state = .saving
        do {
            let rows = try await storage.journals(); try check(token)
            if let found = rows.first(where: { $0.represents(source) }) {
                guard found.publication.target == source.target, found.publication.caption.utf8.elementsEqual(source.caption.utf8), found.publication.descriptor == source.clip.descriptor else { throw AudioCommentStorageFailure.conflict }
                journal = found; state = found.closedReceipt != nil ? .closed : (found.receipt == nil ? .unconfirmed : .published)
            } else {
                guard !rows.contains(where: { ($0.source == source.id || $0.publication.asset == source.id) && $0.isPending }) else { throw AudioCommentFailure(message: "An earlier version is still awaiting confirmation. Its recording is preserved; check that version before publishing another.") }
                state = .ready
            }
        } catch { if token == attempt { state = .unconfirmed }; throw error }
    }
    func publish(_ source: AudioCommentSavedDraft) async throws {
        guard source.target == target, current(), !Task.isCancelled, state != .saving, state != .sending else { throw CancellationError() }
        let token = attempt; journal = nil; state = .saving
        do {
            let prepared = try await storage.prepare(source); try check(token); journal = prepared
            try await send(prepared, token: token)
        } catch { if token == attempt { state = .unconfirmed }; throw error }
    }
    func retry(_ prepared: AudioCommentPublicationJournal) async throws {
        guard prepared.publication.target == target, current(), !Task.isCancelled, state != .saving, state != .sending, prepared.origin == storage.origin, prepared.publication.account == storage.account else { throw CancellationError() }
        let token = attempt; journal = nil; state = .saving
        do {
            let stored = try await storage.journals(); guard let live = stored.first(where: { $0.publication.sameIntent(as: prepared.publication) && $0.source == prepared.source && $0.revision == prepared.revision }) else { throw AudioCommentStorageFailure.conflict }
            try check(token); journal = live; try await send(live, token: token)
        } catch { if token == attempt { state = .unconfirmed }; throw error }
    }
    private func send(_ prepared: AudioCommentPublicationJournal, token: UUID) async throws {
        try check(token)
        if prepared.receipt != nil { state = .published; return }
        if prepared.closedReceipt != nil {state = .closed;return}
        guard let clip = prepared.clip, current(), !Task.isCancelled else { throw CancellationError() }
        state = .sending
        let receipt:AudioCommentPublishedReceipt
        do {receipt=try await transport.publishAudio(.init(publication:prepared.publication,clip:clip),origin:prepared.origin,incarnation:incarnation)}
        catch let proof as AudioCommentPublicationClosed {
            try check(token)
            let closed=try await storage.settleClosed(prepared,proof:proof)
            try check(token);journal=closed;state = .closed;return
        }
        try check(token)
        let committed = try await storage.confirm(prepared, receipt: receipt, retainingAudio: retainAudioOnConfirmation)
        try check(token)
        journal = committed; state = .published
    }
}

/// Live server metadata is distinct from this device's historical publication
/// confirmation. A reader may differ from the author, including a removed author.
struct AudioCommentRemote: Sendable, Equatable, Identifiable {
    let record: Record
    let publication: AudioCommentPublication
    let author: UUID?
    var id: UUID { publication.comment }
    init(record: Record, account: UUID, target: AudioCommentTarget) throws {
        let keys: Set<String> = ["protocol", "account", "operation_id", "comment_id", "asset_id", "author_id", "target", "caption", "audio", "state", "reserved_at", "expires_at", "published_at"]
        guard Set(record.fields.keys) == keys, record["protocol"] == .number(1), record["state"] == .string("published"), record["account"] == .string(account.uuidString.lowercased()) else { throw AudioCommentFailure.invalid }
        switch record["author_id"] {
        case .null: author = nil
        case .string(let value):
            guard let id = UUID(uuidString: value), id != AudioCommentTarget.zero, value == id.uuidString.lowercased() else { throw AudioCommentFailure.invalid }; author = id
        default: throw AudioCommentFailure.invalid
        }
        var intent = record.fields
        for field in ["protocol", "author_id", "state", "reserved_at", "expires_at", "published_at"] { intent.removeValue(forKey: field) }
        intent["version"] = .number(1)
        let publication = try AudioCommentPublication(record: Record(intent))
        guard publication.target == target else { throw AudioCommentFailure.changed }
        // Reuse the strict timestamp/intent checks without treating the reader
        // as the actual author. Never persist this normalized validation record.
        var validation = record.fields; validation["author_id"] = .string(account.uuidString.lowercased())
        _ = try AudioCommentPublishedReceipt(record: Record(validation), publication: publication)
        self.record = record; self.publication = publication
    }
    static func list(_ data: Data, account: UUID, target: AudioCommentTarget) throws -> [Self] {
        guard !data.isEmpty, data.count <= 640_000 else { throw AudioCommentFailure.invalid }
        let envelope = try JSONDecoder().decode(Record.self, from: data)
        guard Set(envelope.fields.keys) == ["protocol", "account", "items"], envelope["protocol"] == .number(1), envelope["account"] == .string(account.uuidString.lowercased()), case .array(let items) = envelope["items"], items.count <= 20 else { throw AudioCommentFailure.invalid }
        let rows = try items.map { value -> Self in
            guard case .object(let fields) = value else { throw AudioCommentFailure.invalid }
            return try .init(record: Record(fields), account: account, target: target)
        }
        guard Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.publication.operation)).count == rows.count, Set(rows.map(\.publication.asset)).count == rows.count else { throw AudioCommentFailure.invalid }
        return rows
    }
}

struct AudioCommentRemoteRemoval: Sendable {
    let comment: UUID
    let operation: UUID
    init(data: Data, expected: AudioCommentRemote) throws {
        guard !data.isEmpty, data.count <= 64_000 else { throw AudioCommentFailure.invalid }
        let row = try JSONDecoder().decode(Record.self, from: data)
        guard Set(row.fields.keys) == ["protocol", "account", "operation_id", "comment_id", "state"], row["protocol"] == .number(1), row["account"] == .string(expected.publication.account.uuidString.lowercased()), row["operation_id"] == .string(expected.publication.operation.uuidString.lowercased()), row["comment_id"] == .string(expected.id.uuidString.lowercased()), ["retired", "purged"].contains(row.string("state")) else { throw AudioCommentFailure.invalid }
        comment = expected.id; operation = expected.publication.operation
    }
}
@MainActor protocol AudioCommentReadingTransport: AnyObject {
    func pageAudio(account: UUID, target: AudioCommentTarget, after: AudioCommentPageCursor?, origin: String, incarnation: UUID) async throws -> AudioCommentPage
    func listAudio(account: UUID, target: AudioCommentTarget, origin: String, incarnation: UUID) async throws -> [AudioCommentRemote]
    func downloadAudio(_ comment: AudioCommentRemote, origin: String, incarnation: UUID) async throws -> AudioCommentClip
    func removeAudio(_ comment: AudioCommentRemote, origin: String, incarnation: UUID) async throws -> AudioCommentRemoteRemoval
}

/// Keep the original timestamp string: a Date formatter can discard PostgreSQL
/// microseconds. Bind local cursors to the reader and exact target, not just time.
struct AudioCommentPageCursor: Sendable, Equatable {
    let account: UUID
    let target: AudioCommentTarget
    let position: Record
    init(position: Record, account: UUID, target: AudioCommentTarget) throws {
        guard Set(position.fields.keys) == ["published_at","comment_id"], case .string(let stamp) = position["published_at"], stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$"#, options:.regularExpression) != nil,
              let id = UUID(uuidString: position.string("comment_id")), id != AudioCommentTarget.zero, position.string("comment_id") == id.uuidString.lowercased() else { throw AudioCommentFailure.invalid }
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard formatter.date(from:stamp) != nil || ISO8601DateFormatter().date(from:stamp) != nil else { throw AudioCommentFailure.invalid }
        self.account=account;self.target=target;self.position=position
    }
}
struct AudioCommentPage: Sendable {
    let items: [AudioCommentRemote]
    let next: AudioCommentPageCursor?
    init(data: Data, account: UUID, target: AudioCommentTarget, after: AudioCommentPageCursor?) throws {
        guard data.count <= 640_000, after == nil || after?.account == account && after?.target == target else { throw AudioCommentFailure.changed }
        let row=try JSONDecoder().decode(Record.self,from:data)
        guard Set(row.fields.keys)==["protocol","account","items","next"] else { throw AudioCommentFailure.invalid }
        var list=row.fields;list.removeValue(forKey:"next")
        items=try AudioCommentRemote.list(JSONEncoder().encode(Record(list)),account:account,target:target)
        switch row["next"] {
        case .null:next=nil
        case .object(let fields):
            let value=try AudioCommentPageCursor(position:Record(fields),account:account,target:target)
            guard items.count==20, let last=items.last, value.position["published_at"]==last.record["published_at"], value.position["comment_id"]==last.record["comment_id"], value != after else { throw AudioCommentFailure.invalid };next=value
        default:throw AudioCommentFailure.invalid
        }
    }
}

/// Presentation admission only. Gateway/SQL still reauthorize every request.
/// Published media reads must not inherit the private draft writer's ownership.
enum AudioCommentReadAdmission {
    static func target(account: String, origin: String, task: Record, projects: [Record], cache: TeamWorkspaceCache?, teamsEnabled: Bool) throws -> AudioCommentTarget {
        guard let actor=UUID(uuidString:account), actor != AudioCommentTarget.zero, actor.uuidString.lowercased()==account,
              TaskKind(task) == .task, let id=UUID(uuidString:task.id), let generation=UUID(uuidString:task.string("task_generation")),
              (try? AudioCommentPublicationJournal.canonicalOrigin(origin))==origin else { throw AudioCommentFailure.changed }
        if let cache, !cache.boundary.belongs(account:account,origin:origin) { throw AudioCommentFailure.changed }
        let project=task.string("project_id")
        if project.isEmpty {
            guard task["project_id"] == .null || task["project_id"] == .string(""), task.string("user_id")==account, cache?.knownTasks.contains(task.id) != true else { throw AudioCommentFailure.changed }
            return try .init(task:id,generation:generation,project:nil)
        }
        guard let projectID=UUID(uuidString:project), projectID.uuidString.lowercased()==project,
              projects.filter({$0.id==project}).count==1, let row=projects.first(where:{$0.id==project}) else { throw AudioCommentFailure.changed }
        guard let cache, let permission=cache.boundary.projects[project] else { throw AudioCommentFailure.changed }
        if let team=cache.knownTeams[project] {
            guard teamsEnabled, cache.boundary.raw["native_team_reads_enabled"] == .bool(true), permission.team==team,
                  ["manager","editor","viewer"].contains(permission.role), cache.knownTasks.contains(task.id) else { throw AudioCommentFailure.changed }
        } else {
            guard !cache.knownTasks.contains(task.id), row["team_id"] == .null || row["team_id"] == .string(""), permission.team == nil,
                  permission.role=="collaborator" || permission.role=="owner" && row.string("user_id")==account else { throw AudioCommentFailure.changed }
        }
        return try .init(task:id,generation:generation,project:projectID)
    }
    static func mayRemove(author: UUID?, account: String, target: AudioCommentTarget, projects: [Record], cache: TeamWorkspaceCache?) -> Bool {
        // Team audio is read-only until its independent publication/removal
        // protocol is accepted. A creator UUID or manager label is no shortcut.
        if let project=target.project?.uuidString.lowercased(), cache?.knownTeams[project] != nil { return false }
        return author?.uuidString.lowercased()==account || target.project.map { id in projects.filter { $0.id==id.uuidString.lowercased() && $0.string("user_id")==account }.count==1 } == true
    }
}

struct AudioCommentReadAccessUnavailable: LocalizedError { var errorDescription: String? { "This audio conversation is no longer available. Refresh access before reopening it." } }
