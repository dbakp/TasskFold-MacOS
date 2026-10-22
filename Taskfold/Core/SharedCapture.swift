import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The only workspace information exposed to the share extension. No credentials or task data.
struct SharedCaptureWorkspace: Codable, Equatable, Sendable {
    let account: String
    let generation: UUID
    let label: String
    func validate() throws {
        guard !account.isEmpty, account.utf8.count <= 200, !label.isEmpty, label.utf8.count <= 400 else {
            throw SharedCaptureFailure("Open Taskfold and choose a workspace before sharing.")
        }
    }
}

struct SharedCaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reviewed plain text and an optional web link. Opening or decoding a draft never creates a task.
struct SharedCaptureContent: Codable, Equatable, Sendable {
    static let maximumTextBytes = 100_000
    var title: String
    var notes: String
    var source: String
    init(title: String, notes: String = "", source: String = "") throws {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate()
    }
    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 10_000,
              title.utf8.count + notes.utf8.count <= Self.maximumTextBytes else {
            throw SharedCaptureFailure("Use a task title and no more than 100 KB of text.")
        }
        if !source.isEmpty {
            guard source.utf8.count <= 8192, let url = URLComponents(string: source),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), url.url != nil else {
                throw SharedCaptureFailure("Use an http or https source link without sign-in details, or remove the link.")
            }
        }
    }
    /// Keep every word of shared text in notes when a compact title is suggested.
    static func suggested(text: String, pageTitle: String = "", source: String = "") throws -> Self {
        guard text.utf8.count <= maximumTextBytes else { throw SharedCaptureFailure("Share no more than 100 KB of text at a time.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed == source.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : trimmed
        let heading = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = String(text.split(whereSeparator: \.isNewline).first ?? "")
        let candidate = !heading.isEmpty ? heading : !firstLine.isEmpty ? firstLine : URLComponents(string: source)?.host ?? "Shared link"
        let title = String(candidate.prefix(200))
        // A long selection remains complete; short single-line text needs no duplicate note.
        return try Self(title: title, notes: text == title ? "" : text, source: source)
    }
    /// Check all provider pieces before allocating their combined selection.
    static func combine(_ texts: [String]) throws -> String {
        var bytes = max(0, texts.count - 1) * 2
        guard bytes <= maximumTextBytes else { throw SharedCaptureFailure("Share no more than 100 KB of text at a time.") }
        for text in texts {
            guard text.utf8.count <= maximumTextBytes - bytes else { throw SharedCaptureFailure("Share no more than 100 KB of text at a time.") }
            bytes += text.utf8.count
        }
        return texts.joined(separator: "\n\n")
    }
    var taskDescription: String {
        [notes, source].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}


/// Share providers may deliver Foundation objects instead of Swift strings.
/// Decode only the requested plain-text/web-link representation; never open a provided file URL.
enum SharedCaptureItem {
    static func text(_ value: NSSecureCoding) throws -> String {
        let text: String
        if let string = value as? String { text = string }
        else if let attributed = value as? NSAttributedString { text = attributed.string }
        else if let data = value as? Data, data.count <= SharedCaptureContent.maximumTextBytes, let decoded = String(data: data, encoding: .utf8) { text = decoded }
        else { throw SharedCaptureFailure("The source app did not provide readable plain text.") }
        guard text.utf8.count <= SharedCaptureContent.maximumTextBytes else { throw SharedCaptureFailure("Share no more than 100 KB of text at a time.") }
        return text
    }
    static func webLink(_ value: NSSecureCoding) throws -> String {
        let source = try (value as? URL).map { $0.absoluteString } ?? text(value)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedCaptureFailure("The source app did not include a web link.") }
        return try SharedCaptureContent(title: "Shared link", source: source).source
    }
}

struct SharedCaptureDraft: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspace: SharedCaptureWorkspace
    let createdAt: Date
    var content: SharedCaptureContent
    init(id: UUID = UUID(), workspace: SharedCaptureWorkspace, content: SharedCaptureContent, at date: Date = Date()) throws {
        self.id = id; self.workspace = workspace; self.content = content; createdAt = date
        try validate()
    }
    func validate() throws {
        try workspace.validate(); try content.validate()
        guard createdAt.timeIntervalSince1970.isFinite else { throw SharedCaptureFailure("This draft has an invalid date.") }
    }
    /// Retries keep one identity. A recipient never supplies an arbitrary existing task ID.
    var taskID: String { id.uuidString.lowercased() }
}

/// A credential-free, locked draft mailbox shared by the app and its native extension.
/// Its workspace binding is rechecked inside the same lock as every save.
final class SharedCaptureDisk: @unchecked Sendable {
    static let group = "group.com.dbakp.taskfold"
    static let capacity = 64
    static let maximumFileBytes = 8_000_000
    private static let processLock = NSLock()
    private let directory: URL
    private struct State: Codable {
        var version = 1
        var workspace: SharedCaptureWorkspace?
        var drafts: [SharedCaptureDraft] = []
    }
    init(directory: URL) { self.directory = directory }
    static func system() throws -> SharedCaptureDisk {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw SharedCaptureFailure("Open Taskfold once to connect sharing to your workspace.")
        }
        return Self(directory: directory)
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("shared-capture.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SharedCaptureFailure("This draft could not be saved. Try again after opening Taskfold.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SharedCaptureFailure("Sharing is busy. Please try again.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    private var url: URL { directory.appendingPathComponent("shared-capture.json") }
    private func read() throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumFileBytes {
            guard let part = try handle.read(upToCount: min(65_536, Self.maximumFileBytes + 1 - data.count)), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count <= Self.maximumFileBytes else { throw SharedCaptureFailure("Saved sharing data needs attention. Open Taskfold before trying again.") }
        let state: State
        do { state = try JSONDecoder().decode(State.self, from: data) }
        catch { throw SharedCaptureFailure("Saved drafts couldn’t be read. They have been kept on this device, and your tasks are unchanged.") }
        guard state.version == 1, state.drafts.count <= Self.capacity, Set(state.drafts.map(\.id)).count == state.drafts.count else {
            throw SharedCaptureFailure("Saved sharing data needs a supported version of Taskfold.")
        }
        try state.workspace?.validate()
        for draft in state.drafts { try draft.validate() }
        return state
    }
    private func write(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumFileBytes else { throw SharedCaptureFailure("Open Taskfold to review saved drafts before sharing more.") }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func removeAccount(_ account: String) throws {
        try locked {
            var state = try read()
            state.drafts.removeAll { $0.workspace.account == account }
            if state.workspace?.account == account { state.workspace = nil }
            try write(state)
        }
    }
    func publish(_ workspace: SharedCaptureWorkspace?) throws {
        try workspace?.validate()
        try locked { var state = try read(); state.workspace = workspace; try write(state) }
    }
    func workspace() throws -> SharedCaptureWorkspace? { try locked { try read().workspace } }
    /// Idempotent within a share presentation, including a callback retried after a successful write.
    func save(_ draft: SharedCaptureDraft) throws {
        try draft.validate()
        try locked {
            var state = try read()
            guard state.workspace == draft.workspace else { throw SharedCaptureFailure("Your Taskfold workspace changed. Close sharing and review it again.") }
            if let existing = state.drafts.first(where: { $0.id == draft.id }) {
                guard existing == draft else { throw SharedCaptureFailure("This draft was already saved with different content. Reopen sharing to make a new draft.") }
                return
            }
            guard state.drafts.count < Self.capacity else { throw SharedCaptureFailure("Open Taskfold to review saved drafts before sharing more.") }
            state.drafts.append(draft); try write(state)
        }
    }
    func drafts(account: String) throws -> [SharedCaptureDraft] {
        try locked {
            let state = try read()
            guard !account.isEmpty, state.workspace?.account == account else { return [] }
            return state.drafts.filter { $0.workspace.account == account }
        }
    }
    /// Removing one exact draft never clears another account's drafts or a newer edited copy.
    func acknowledge(_ draft: SharedCaptureDraft, account: String) throws {
        try locked {
            var state = try read()
            guard !account.isEmpty, state.workspace?.account == account, draft.workspace.account == account else {
                throw SharedCaptureFailure("Reopen shared drafts in their original workspace.")
            }
            state.drafts.removeAll { $0 == draft }; try write(state)
        }
    }
}

/// A single caller-owned deadline spans all attachments. Cancellation and late
/// producer callbacks race through one gate; neither can resume a reader twice.
/// NSItemProvider owns its underlying work; loadItem has no cancellable Progress.
enum SharedCaptureProvider {
    static func read(_ provider: NSItemProvider, type: String, deadline: ContinuousClock.Instant) async throws -> NSSecureCoding {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw SharedCaptureFailure("The source app took too long. Close sharing and try again.") }
        let gate = Gate()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let timer = Task {
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        gate.finish(.failure(SharedCaptureFailure("The source app took too long. Close sharing and try again.")))
                    } catch {}
                }
                gate.attach(timer)
                guard gate.active else { return }
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                    if error != nil { gate.finish(.failure(SharedCaptureFailure("The source app couldn’t provide this item. Close sharing and try again."))) }
                    else if let item { gate.finish(.success(item)) }
                    else { gate.finish(.failure(SharedCaptureFailure("The source app did not include readable content."))) }
                }
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        return value
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var pending: Result<NSSecureCoding, Error>?
        private var continuation: CheckedContinuation<NSSecureCoding, Error>?
        private var timer: Task<Void, Never>?
        var active: Bool { lock.lock(); defer { lock.unlock() }; return !completed }
        func install(_ value: CheckedContinuation<NSSecureCoding, Error>) -> Bool {
            lock.lock()
            if completed { let result = pending ?? .failure(CancellationError()); pending = nil; lock.unlock(); value.resume(with: result); return false }
            continuation = value; lock.unlock(); return true
        }
        func attach(_ value: Task<Void,Never>) {
            lock.lock(); let cancel = completed; if !cancel { timer = value }; lock.unlock()
            if cancel { value.cancel() }
        }
        func finish(_ result: Result<NSSecureCoding,Error>) {
            lock.lock(); guard !completed else { lock.unlock(); return }
            completed = true
            let reader = continuation; continuation = nil
            if reader == nil { pending = result }
            let deadline = timer; timer = nil; lock.unlock()
            deadline?.cancel(); reader?.resume(with: result)
        }
    }
}

/// Only text and one web link become a draft. Known ancillary Maps previews
/// remain unread, and are omitted only when the place also supplies a valid link.
/// Any other unsupported attachment still refuses the entire intake.
struct SharedCaptureIntake: Sendable {
    let content: SharedCaptureContent
    let omittedMapPreview: Bool
    static func read(_ items: [NSExtensionItem], deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(20))) async throws -> Self {
        try Task.checkCancellation()
        guard !items.isEmpty, items.count <= 4 else { throw SharedCaptureFailure("Share text or one web link at a time.") }
        var texts: [String] = [], links: [String] = [], pageTitle = "", count = 0, mapPreviews = 0
        for item in items {
            if pageTitle.isEmpty { pageTitle = item.attributedTitle?.string ?? "" }
            if let text = item.attributedContentText?.string, !text.isEmpty {
                guard text.utf8.count <= SharedCaptureContent.maximumTextBytes else { throw SharedCaptureFailure("Share no more than 100 KB of text at a time.") }
                texts.append(text)
            }
            for provider in item.attachments ?? [] {
                count += 1
                guard count <= 8 else { throw SharedCaptureFailure("Share text or one web link at a time.") }
                if provider.hasItemConformingToTypeIdentifier("public.url") {
                    let value = try await SharedCaptureProvider.read(provider, type: "public.url", deadline: deadline)
                    let link = try SharedCaptureItem.webLink(value)
                    if !links.contains(link) { links.append(link) }
                } else if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
                    let value = try await SharedCaptureProvider.read(provider, type: "public.plain-text", deadline: deadline)
                    let text = try SharedCaptureItem.text(value)
                    if !texts.contains(text) { texts.append(text) }
                } else if provider.registeredTypeIdentifiers == ["com.apple.mapkit.map-item"] {
                    mapPreviews += 1 // Do not ask the provider to decode the opaque object.
                } else { throw SharedCaptureFailure("This version captures text and web links. Share a text selection or link instead of a file.") }
                guard texts.reduce(0, { $0 + $1.utf8.count }) <= SharedCaptureContent.maximumTextBytes, links.count <= 1 else {
                    throw SharedCaptureFailure("Share no more than 100 KB of text and one web link at a time.")
                }
            }
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw SharedCaptureFailure("The source app took too long. Close sharing and try again.") }
        guard mapPreviews == 0 || !links.isEmpty else { throw SharedCaptureFailure("Share a web link for this place instead of a map file.") }
        guard !texts.isEmpty || !links.isEmpty else { throw SharedCaptureFailure("The source app did not include text or a web link.") }
        let content = try SharedCaptureContent.suggested(text: SharedCaptureContent.combine(texts), pageTitle: pageTitle, source: links.first ?? "")
        return Self(content: content, omittedMapPreview: mapPreviews > 0)
    }
}
