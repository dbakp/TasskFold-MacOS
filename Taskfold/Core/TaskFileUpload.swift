import Foundation
import CryptoKit
import Observation

/// Frozen local bytes and server intent. Never placed in the optimistic task queue.
struct TaskFileUploadJournal: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Phase: String, Codable, Sendable { case queued, attempted, published, cancelled, expired }
    static let storagePrefix = "task-file-upload-v1."
    static let fileName = "upload.taskfoldfile"
    static let encryptionContext = "com.taskfold.task-file-upload.v1"
    static let maximumStoredBytes = 7_100_000
    static let encodingOptions: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
    static let maximumBytes = 5 * 1024 * 1024
    static let types = ["application/pdf", "application/octet-stream", "application/zip", "image/png", "image/jpeg", "image/webp", "text/plain"]
    static var invalid: AppFailure { AppFailure(message: "This saved file needs review. Your original copy is kept.") }
    let account: String, origin: String, intent: Record, bytes: Data
    private(set) var phase: Phase
    private(set) var receipt: Record?
    var id: String { intent.string("operation_id") }
    var target: Record { Record(intent["target"].object) }
    var name: String { intent.string("name") }
    var resolved: Bool { [.published, .cancelled, .expired].contains(phase) }
    var description: String { "Private saved file upload" }
    var debugDescription: String { description }
    static func validID(_ value: String) -> Bool { UUID(uuidString: value).map { $0 != AudioCommentTarget.zero && $0.uuidString.lowercased() == value } == true }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(account: String, origin: String, target: Record, bytes: Data, name: String, type: String, operation: UUID = UUID()) throws {
        let intent = Record(["operation_id": .string(operation.uuidString.lowercased()), "target": .object(target.fields), "name": .string(name), "type": .string(type), "byte_count": .number(Double(bytes.count)), "sha256": .string(Self.digest(bytes))])
        try self.init(account: account, origin: origin, intent: intent, bytes: bytes, phase: .queued, receipt: nil)
    }
    private init(account: String, origin: String, intent: Record, bytes: Data, phase: Phase, receipt: Record?) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard Self.validID(account), try AudioCommentPublicationJournal.canonicalOrigin(origin) == origin,
              Set(intent.fields.keys) == ["operation_id", "target", "name", "type", "byte_count", "sha256"], Self.validID(intent.string("operation_id")),
              case .object(let target) = intent["target"], Set(target.keys) == ["team_id", "project_id", "task_id", "task_generation"],
              target.values.allSatisfy({ if case .string(let id) = $0 { return Self.validID(id) }; return false }),
              !bytes.isEmpty, bytes.count <= Self.maximumBytes, intent["byte_count"] == .number(Double(bytes.count)), intent["sha256"] == .string(Self.digest(bytes)),
              case .string(let name) = intent["name"], !name.isEmpty, name.utf16.count <= 240, ![".", ".."].contains(name),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" }),
              case .string(let type) = intent["type"], Self.types.contains(type), phase == .queued || phase == .attempted || receipt != nil else { throw Self.invalid }
        self.account = account; self.origin = origin; self.intent = intent; self.bytes = bytes; self.phase = phase; self.receipt = receipt
        if let receipt { guard try validated(receipt) == phase, resolved else { throw Self.invalid } }
        else { guard !resolved else { throw Self.invalid } }
    }
    private func validated(_ r: Record) throws -> Phase {
        if r.fields["sender_stop_protocol"] != nil {
            guard Set(r.fields.keys) == ["protocol", "sender_stop_protocol", "account", "operation_id", "state"],
                  r["protocol"] == .number(1), r["sender_stop_protocol"] == .number(1), r["account"] == .string(account),
                  r["operation_id"] == intent["operation_id"], r["state"] == .string("cancelled") else { throw Self.invalid }
            return .cancelled
        }
        guard Set(r.fields.keys) == ["protocol", "account", "operation_id", "target", "state", "attachment"],
              r["protocol"] == .number(1), r["account"] == .string(account), r["operation_id"] == intent["operation_id"], r["target"] == intent["target"],
              case .string(let state) = r["state"], ["reserved", "published", "cancelled", "expired"].contains(state), let phase = Phase(rawValue: state == "reserved" ? "attempted" : state) else { throw Self.invalid }
        if phase == .published {
            guard case .object(let a) = r["attachment"], Set(a.keys) == ["id", "storage_object_id", "name", "size", "type", "sha256", "uploadedAt"],
                  a["id"] == intent["operation_id"], a["name"] == intent["name"], a["size"] == intent["byte_count"], a["type"] == intent["type"], a["sha256"] == intent["sha256"],
                  case .string(let object) = a["storage_object_id"], Self.validID(object), case .string(let time) = a["uploadedAt"], time.utf8.count <= 40 else { throw Self.invalid }
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard fractional.date(from: time) != nil || ISO8601DateFormatter().date(from: time) != nil else { throw Self.invalid }
        } else { guard r["attachment"] == .null else { throw Self.invalid } }
        return phase
    }
    func markingAttempted() throws -> Self {
        guard !resolved else { throw Self.invalid }
        return try .init(account: account, origin: origin, intent: intent, bytes: bytes, phase: .attempted, receipt: nil)
    }
    func receiving(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 64000, phase != .queued else { throw Self.invalid }
        let envelope = try TaskfoldJSONDecoder().decode(Record.self, from: data)
        guard Set(envelope.fields.keys) == ["receipt"], case .object(let fields) = envelope["receipt"] else { throw Self.invalid }
        let r = Record(fields), state = try validated(r)
        if resolved { guard receipt == r else { throw Self.invalid }; return self }
        return try .init(account: account, origin: origin, intent: intent, bytes: bytes, phase: state, receipt: state == .attempted ? nil : r)
    }
    func matchesTarget(_ target: Record) -> Bool { self.target == target }
    private enum CodingKeys: String, CodingKey { case account, origin, intent, bytes, phase, receipt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try decoder.container(keyedBy: TaskFileCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)) == ["account", "origin", "intent", "bytes", "phase", "receipt"] else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), intent: c.decode(Record.self, forKey: .intent), bytes: c.decode(Data.self, forKey: .bytes), phase: c.decode(Phase.self, forKey: .phase), receipt: c.decodeIfPresent(Record.self, forKey: .receipt))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(intent, forKey: .intent); try c.encode(bytes, forKey: .bytes); try c.encode(phase, forKey: .phase); try c.encode(receipt, forKey: .receipt)
    }
}
private struct TaskFileCodingKey: CodingKey { let stringValue: String; let intValue: Int? = nil; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
typealias TaskFileUploadVault = ReviewedTeamCommandVault<TaskFileUploadJournal>
@MainActor protocol TaskFileUploadTransport: AnyObject {
    func taskFileReply(_ journal: TaskFileUploadJournal, action: String, incarnation: UUID) async throws -> Data
}

/// Every possible network send follows durable attempted-state admission.
/// A late reply after a scope change leaves that attempted original for later
/// authenticated recovery; the next workspace is never touched.
@MainActor @Observable final class TaskFileUploadModel {
    private(set) var pending: TaskFileUploadJournal?
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var needsRefresh = false
    let account: String, origin: String, target: Record
    @ObservationIgnored private let vault: TaskFileUploadVault
    @ObservationIgnored private let service: any TaskFileUploadTransport
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let publishAllowed: () -> Bool
    @ObservationIgnored private let incarnation: UUID
    @ObservationIgnored private let publicationConfirmed: () async -> Void
    @ObservationIgnored private var lease = CalendarReadLease()
    @ObservationIgnored private var closed = false
    init(account: String, origin: String, target: Record, vault: TaskFileUploadVault, service: any TaskFileUploadTransport, incarnation: UUID, current: @escaping () -> Bool, publishAllowed: @escaping () -> Bool = { true }, publicationConfirmed: @escaping () async -> Void = {}) {
        self.account = account; self.origin = origin; self.target = target; self.vault = vault; self.service = service; self.incarnation = incarnation; self.current = current; self.publishAllowed = publishAllowed; self.publicationConfirmed = publicationConfirmed
    }
    var available: Bool { !closed && current() }
    var sameTarget: Bool { pending?.matchesTarget(target) == true }
    var canPublish: Bool { available && !needsRefresh && sameTarget && publishAllowed() }
    func close() { closed = true; lease.cancel(); pending = nil; loaded = false; message = nil; needsRefresh = false }
    private func check() throws { try lease.check(); guard available, !Task.isCancelled else { throw CancellationError() } }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); let saved = try await vault.pending(account: account, origin: origin); try check(); pending = saved; loaded = true; needsRefresh = false; message = nil }
        catch { if available { needsRefresh = true; message = pending == nil ? "Your saved upload couldn’t be opened. Nothing new was sent." : "Saved recovery couldn’t be refreshed. Your current local copy is kept." } }
    }
    func choose(_ data: Data, name: String, type: String) async {
        guard !busy, loaded, !needsRefresh, pending == nil else { return }; busy = true; defer { busy = false }
        do { try check(); let value = try TaskFileUploadJournal(account: account, origin: origin, target: target, bytes: data, name: name, type: type); try await vault.begin(value, lease: lease); try check(); pending = value; message = nil }
        catch { if available { message = "The file couldn’t be saved for upload. Choose a supported file up to 5 MB, or reopen saved recovery." } }
    }
    func act(_ action: String) async {
        guard !busy, loaded, !needsRefresh, let expected = pending, !expected.resolved, ["publish", "resolve", "cancel"].contains(action), action != "publish" || canPublish,
              action != "resolve" || expected.phase == .attempted else { return }
        busy = true; defer { busy = false }
        var updatingRecovery = true
        do {
            try check()
            if action == "cancel", expected.phase == .queued {
                try await vault.clear(expected, lease: lease); try check(); pending = nil; message = "The local upload was removed before sending."; return
            }
            let attempted = try expected.markingAttempted()
            try await vault.replace(expected, with: attempted, lease: lease)
            try check(); pending = attempted
            updatingRecovery = false
            let data = try await service.taskFileReply(attempted, action: action, incarnation: incarnation)
            let received = try attempted.receiving(data)
            // Scope/lease changes intentionally leave the attempted original for
            // authenticated recovery rather than accepting a late UI reply.
            try check(); updatingRecovery = true
            try await vault.replace(attempted, with: received, lease: lease); try check()
            pending = received; message = received.phase == .published ? "File shared" : received.resolved ? "Upload stopped. Your local copy is kept." : "This upload is still pending. Its original file is saved."
            // Refresh through the owning Store only after the validated receipt is
            // durable. Stop can return an already-published result too. A refresh
            // cannot replace the journal or invent a local attachment from a receipt.
            if received.phase == .published { await publicationConfirmed() }
        } catch {
            if available {
                needsRefresh = updatingRecovery
                message = updatingRecovery ? "Saved recovery changed or couldn’t be updated. Refresh saved upload before continuing. Your current local copy is kept." : "The result couldn’t be confirmed. Your file is saved. Check its status or retry the same upload."
            }
        }
    }
    func finish() async {
        guard !busy, !needsRefresh, let expected = pending, expected.resolved else { return }; busy = true; defer { busy = false }
        do { try check(); try await vault.clear(expected, lease: lease); try check(); pending = nil; message = "Recovery copy cleared. Shared files are unchanged." }
        catch { if available { needsRefresh = true; message = "Recovery changed or couldn’t be cleared. Refresh saved upload before continuing." } }
    }
}

/// Read authority comes from the current verified workspace, never a creator
/// UUID, historical custody, editor admission or an upload-recovery receipt.
enum TaskFileReadAdmission {
    static func target(account: String, origin: String, task: Record, projects: [Record], cache: TeamWorkspaceCache?, teamsEnabled: Bool) throws -> Record {
        guard teamsEnabled, TeamProjectValue.id(account), TeamProjectValue.id(task.id), TeamProjectValue.id(task.string("task_generation")),
              let cache, cache.boundary.belongs(account: account, origin: origin),
              cache.boundary.raw["native_team_reads_enabled"] == .bool(true),
              projects.filter({ $0.id == task.string("project_id") }).count == 1,
              let permission = cache.boundary.projects[task.string("project_id")], let team = permission.team,
              cache.knownTeams[permission.id] == team, cache.knownTasks.contains(task.id),
              ["manager", "editor", "viewer"].contains(permission.role) else { throw TaskFileUploadJournal.invalid }
        return Record(["team_id": .string(team), "project_id": .string(permission.id), "task_id": .string(task.id), "task_generation": task["task_generation"]])
    }
    static func matches(_ target: Record, source: Record) -> Bool {
        source.id == target.string("task_id") && source["task_generation"] == target["task_generation"] && source["project_id"] == target["project_id"]
    }
}
