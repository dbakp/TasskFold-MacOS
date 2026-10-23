import Foundation
import CryptoKit
import Security
import Darwin
import Observation

enum WebhookEvent: String, CaseIterable, Codable, Sendable {
    case created = "task.created", updated = "task.updated", completed = "task.completed", reopened = "task.reopened", deleted = "task.deleted"
    var title: String { switch self { case .created: "Created"; case .updated: "Edited or moved"; case .completed: "Completed"; case .reopened: "Reopened"; case .deleted: "Deleted" } }
}
/// Secret-bearing values never enter snapshots, backups, preferences or logs.
struct WebhookDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String, account: String, origin: String, name: String, endpoint: String, scope: String
    let project: String?
    let events: [WebhookEvent]
    let days: Int
    private let rawSecret: String
    var description: String { "Webhook setup (private configuration redacted)" }
    var debugDescription: String { description }
    var secret: String { rawSecret }
    init(account: String, origin: String, name: String, endpoint: String, scope: String, project: String?, events: Set<WebhookEvent>, days: Int, id: UUID = UUID(), entropy: () throws -> Data = WebhookDraft.entropy) throws {
        guard AutomationKey.canonicalID(account), id != UUID(uuidString: WebhookValue.nilID), WebhookValue.origin(origin),
              WebhookValue.name(name), WebhookValue.endpoint(endpoint), ["all", "inbox", "project"].contains(scope),
              scope == "project" ? (project != nil && AutomationKey.canonicalID(project!) && project != WebhookValue.nilID) : project == nil,
              !events.isEmpty, [30, 90, 365].contains(days) else { throw WebhookValue.invalid }
        let bytes = try entropy(); guard bytes.count == 32 else { throw WebhookValue.invalid }
        self.id = id.uuidString.lowercased(); self.account = account; self.origin = origin; self.name = name; self.endpoint = endpoint
        self.scope = scope; self.project = project; self.events = events.sorted { $0.rawValue < $1.rawValue }; self.days = days
        rawSecret = "tfwh_v1_" + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var body: [String: JSON] { ["id": .string(id), "name": .string(name), "endpoint": .string(endpoint), "scope": .string(scope), "project_id": project.map(JSON.string) ?? .null, "events": .array(events.map { .string($0.rawValue) }), "ttl_days": .number(Double(days)), "secret": .string(rawSecret)] }
    private static func entropy() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WebhookValue.invalid }; return Data(bytes)
    }
}
enum WebhookValue {
    static let nilID = "00000000-0000-0000-0000-000000000000"
    static var invalid: AppFailure { AppFailure(message: "The connection was not confirmed. Reload and review its settings before trying again.") }
    static func name(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s == s.trimmingCharacters(in: .whitespacesAndNewlines) && s.unicodeScalars.count <= 80 && s.utf8.count <= 320 && !s.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    static func origin(_ s: String) -> Bool { guard let c = URLComponents(string: s) else { return false }; return c.scheme == "https" && c.host?.isEmpty == false && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil && c.path.isEmpty }
    static func sameReceiverOrigin(_ origin: String, _ endpoint: String) -> Bool {
        guard let a = URL(string:origin), let b = URL(string:endpoint), a.scheme == "https", b.scheme == "https", (a.port ?? 443) == (b.port ?? 443), let ah = a.host?.lowercased(), let bh = b.host?.lowercased() else { return false }
        if ah == bh { return true }
        let left = ah.trimmingCharacters(in:CharacterSet(charactersIn:"[]")), right = bh.trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        var x = in6_addr(), y = in6_addr()
        guard inet_pton(AF_INET6,left,&x) == 1, inet_pton(AF_INET6,right,&y) == 1 else { return false }
        return withUnsafeBytes(of:&x) { Data($0) } == withUnsafeBytes(of:&y) { Data($0) }
    }
    static func receiverOrigin(_ s: String) -> String? { guard let url = URL(string:s), let host = url.host else { return nil }; var c = URLComponents(); c.scheme = "https"; c.host = host.lowercased(); return c.string }
    static func endpoint(_ s: String) -> Bool { guard s.utf8.count <= 2048, !s.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }), let c = URLComponents(string: s), c.scheme == "https", c.host?.isEmpty == false, c.user == nil, c.password == nil, c.fragment == nil else { return false }; return c.port == nil || c.port == 443 }
    static func date(_ v: JSON?) -> Date? { guard case .string(let s) = v, s.count <= 40, s.contains("T") else { return nil }; let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
    static func count(_ row: [String: JSON], _ key: String, max: Int = 2147483647) throws -> Int { guard case .number(let n) = row[key], n.isFinite, n >= 0, n <= Double(max), n.rounded() == n else { throw invalid }; return Int(n) }
    static let errors: Set<String> = ["quota", "configuration", "refused", "gone", "temporary", "expired", "attempts_exhausted", "connection_unavailable", "resource_unavailable", "account_unavailable"]
}
struct WebhookDelivery: Equatable, Sendable {
    let pending: Int, retainedBytes: Int, missed: Int, delivered: Int, failed: Int
    let captureIssue: String?, blocked: String?, error: String?
    init(_ row: [String: JSON]) throws {
        guard row["version"] == .number(1) else { throw WebhookValue.invalid }
        pending = try WebhookValue.count(row,"pending",max:256); retainedBytes = try WebhookValue.count(row,"retained_bytes",max:33554432)
        missed = try WebhookValue.count(row,"missed"); delivered = try WebhookValue.count(row,"delivered"); failed = try WebhookValue.count(row,"failed")
        for (key, values) in [("capture_issue", Set(["event_quota","queue_capacity","payload_too_large"])), ("blocked_reason", Set(["configuration","refused","gone"])), ("last_error", WebhookValue.errors)] {
            guard row[key] == .null || values.contains(row[key]?.text ?? "") else { throw WebhookValue.invalid }
        }
        for key in ["missed_since","missed_until","last_success","last_failure"] { guard row[key] == .null || WebhookValue.date(row[key]) != nil else { throw WebhookValue.invalid } }
        captureIssue = row["capture_issue"] == .null ? nil : row["capture_issue"]?.text
        blocked = row["blocked_reason"] == .null ? nil : row["blocked_reason"]?.text; error = row["last_error"] == .null ? nil : row["last_error"]?.text
    }
    var recovery: String? {
        if missed > 0 { return "\(missed) changes weren’t queued. Refresh your tool’s copy of these tasks from Taskfold before relying on it again. This count is cumulative. Resuming won’t replay missing changes." }
        switch blocked { case "gone": return "The receiver is no longer available. Check it before resuming. Failed deliveries need a separate Retry."; case "refused": return "The receiver refused delivery. Check its settings and permissions before resuming."; case "configuration": return "Delivery is waiting for a secure server configuration. Contact the service administrator; your tasks remain saved."; default: break }
        return error == "quota" ? "Delivery is waiting for its sending allowance to reset. Queued changes expire after 24 hours." : nil
    }
}
struct WebhookConnection: Identifiable, Equatable, Sendable {
    let id: String, revision: String, name: String, origin: String, scope: String, state: String
    let project: String?
    let events: [WebhookEvent]
    let created: Date, expires: Date
    let delivery: WebhookDelivery
    init(_ row: [String: JSON]) throws {
        let id = row["id"]?.text ?? "", revision = row["revision"]?.text ?? "", name = row["name"]?.text ?? "", origin = row["origin"]?.text ?? "", scope = row["scope"]?.text ?? "", state = row["state"]?.text ?? ""
        let events = row["events"]?.list.compactMap { WebhookEvent(rawValue: $0.text) } ?? []
        guard AutomationKey.canonicalID(id), AutomationKey.canonicalID(revision), WebhookValue.name(name), WebhookValue.origin(origin), ["all","inbox","project"].contains(scope), ["pending","active","paused","revoked","expired"].contains(state),
              !events.isEmpty, events.count == row["events"]?.list.count, Set(events).count == events.count,
              scope == "project" ? AutomationKey.canonicalID(row["project_id"]?.text ?? "") : row["project_id"] == .null,
              let created = WebhookValue.date(row["created_at"]), let expires = WebhookValue.date(row["expires_at"]), expires > created,
              case .object(let summary) = row["delivery"] else { throw WebhookValue.invalid }
        for key in ["verified_at","revoked_at"] { guard row[key] == .null || WebhookValue.date(row[key]) != nil else { throw WebhookValue.invalid } }
        self.id = id; self.revision = revision; self.name = name; self.origin = origin; self.scope = scope; self.state = state; project = scope == "project" ? row["project_id"]?.text : nil
        self.events = events; self.created = created; self.expires = expires; delivery = try WebhookDelivery(summary)
    }
    var usable: Bool { !["expired","revoked"].contains(state) && expires > Date() }
}
struct WebhookHistoryEvent: Identifiable, Equatable, Sendable {
    let id: String, type: String, status: String, taskID: String, generation: String
    let parts: Int, partsDelivered: Int, attempts: Int, manualRetries: Int
    let created: Date, expires: Date
    let error: String?
    init(_ row: [String: JSON]) throws {
        let id = row["id"]?.text ?? "", type = row["type"]?.text ?? "", status = row["status"]?.text ?? "", task = row["task_id"]?.text ?? "", gen = row["task_generation"]?.text ?? ""
        guard [id,task,gen].allSatisfy(AutomationKey.canonicalID), (WebhookEvent(rawValue:type) != nil || type == "task.removed"), ["pending","leased","failed","delivered","cancelled","expired"].contains(status),
              let created = WebhookValue.date(row["created_at"]), let expires = WebhookValue.date(row["expires_at"]), WebhookValue.date(row["next_attempt_at"]) != nil,
              row["finished_at"] == .null || WebhookValue.date(row["finished_at"]) != nil,
              row["error"] == .null || WebhookValue.errors.contains(row["error"]?.text ?? "") else { throw WebhookValue.invalid }
        parts = try WebhookValue.count(row,"parts",max:94); partsDelivered = try WebhookValue.count(row,"parts_delivered",max:parts)
        attempts = try WebhookValue.count(row,"attempts"); manualRetries = try WebhookValue.count(row,"manual_retries",max:3)
        guard parts > 0 else { throw WebhookValue.invalid }
        if row["http_status"] != .null { let n = try WebhookValue.count(row,"http_status",max:599); guard n >= 100 else { throw WebhookValue.invalid } }
        self.id = id; self.type = type; self.status = status; taskID = task; generation = gen; self.created = created; self.expires = expires; error = row["error"] == .null ? nil : row["error"]?.text
    }
    var retryable: Bool { status == "failed" && expires > Date() && manualRetries < 3 }
}

private struct WebhookEnvelope: Codable {
    let version: Int
    let id: String, account: String, origin: String, name: String, endpoint: String, scope: String, secret: String
    let project: String?
    let events: [WebhookEvent]
    let days: Int
    let cancelling: Bool
    init(_ d: WebhookDraft, cancelling: Bool = false) { version = 1; id = d.id; account = d.account; origin = d.origin; name = d.name; endpoint = d.endpoint; scope = d.scope; project = d.project; events = d.events; days = d.days; secret = d.secret; self.cancelling = cancelling }
    func draft() throws -> WebhookDraft {
        guard version == 1, AutomationKey.canonicalID(id), events.count == Set(events).count, secret.hasPrefix("tfwh_v1_"), secret.utf8.count == 51,
              let bytes = Data(base64Encoded:String(secret.suffix(43)).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+"=") else { throw WebhookValue.invalid }
        let d = try WebhookDraft(account:account,origin:origin,name:name,endpoint:endpoint,scope:scope,project:project,events:Set(events),days:days,id:UUID(uuidString:id)!,entropy:{bytes})
        guard d.secret == secret else { throw WebhookValue.invalid }; return d
    }
}
struct WebhookRecovery: Sendable { let draft: WebhookDraft; let cancelling: Bool }
actor WebhookEnrollmentVault {
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    init(io: any CalendarSecureItemIO, coordinationDirectory: URL? = nil) {
        precondition(coordinationDirectory != nil || !(io is CalendarKeychainIO)); self.io = io; lock = AutomationEnrollmentProcessLock(directory:coordinationDirectory)
    }
    private func key(_ account: String) throws -> String { guard AutomationKey.canonicalID(account) else { throw WebhookValue.invalid }; return "webhook-enrollment-v1." + account }
    private func read(_ account: String, _ origin: String) throws -> WebhookRecovery? {
        guard let data = try io.read(key:key(account)) else { return nil }
        guard data.count <= 8192, let e = try? JSONDecoder().decode(WebhookEnvelope.self,from:data), let d = try? e.draft(), d.account == account else { throw WebhookValue.invalid }
        guard d.origin == origin else { throw AppFailure(message:"Return to the original account server to finish this connection.") }; return WebhookRecovery(draft:d,cancelling:e.cancelling)
    }
    func recovery(account: String, origin: String) throws -> WebhookRecovery? { try lock.withExclusive(account:account) { try read(account,origin) } }
    func begin(_ d: WebhookDraft, lease: CalendarReadLease) throws -> WebhookRecovery {
        try lock.withExclusive(account:d.account,check:{try lease.check()}) {
            if let old = try read(d.account,d.origin) { return old }
            let bytes = try JSONEncoder().encode(WebhookEnvelope(d)); guard bytes.count <= 8192 else { throw WebhookValue.invalid }; try lease.check(); try io.write(bytes,key:key(d.account)); return WebhookRecovery(draft:d,cancelling:false)
        }
    }
    func cancel(_ d: WebhookDraft, lease: CalendarReadLease) throws {
        try lock.withExclusive(account:d.account,check:{try lease.check()}) {
            guard let old = try read(d.account,d.origin), old.draft.body == d.body else { throw CancellationError() }
            try lease.check(); try io.write(try JSONEncoder().encode(WebhookEnvelope(d,cancelling:true)),key:key(d.account))
        }
    }
    func finish(_ d: WebhookDraft, lease: CalendarReadLease, cancelled: Bool = false) throws {
        try lock.withExclusive(account:d.account,check:{try lease.check()}) {
            guard let old = try read(d.account,d.origin) else { return }
            guard old.draft.body == d.body, !old.cancelling || cancelled else { throw CancellationError() }
            try lease.check(); try io.remove(key:key(d.account))
        }
    }
    func removeAccount(_ account: String, origin: String) throws {
        try lock.withExclusive(account:account) {
            guard let bytes = try io.read(key:key(account)) else { return }
            guard bytes.count <= 8192, let envelope = try? JSONDecoder().decode(WebhookEnvelope.self,from:bytes), let d = try? envelope.draft(), d.account == account else { throw WebhookValue.invalid }
            if d.origin == origin { try io.remove(key:key(account)) }
        }
    }
}
@MainActor protocol WebhookService: AnyObject { func webhookReceipt(action: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] }
extension Backend: WebhookService {}

@MainActor @Observable private final class WebhookSecretReviews { static let shared = WebhookSecretReviews(); var finished = Set<String>() }

@MainActor @Observable final class WebhookAccessModel {
    private(set) var connections: [WebhookConnection] = []
    private(set) var pending: WebhookRecovery?
    private(set) var confirmed: WebhookConnection?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var needsSignIn = false
    private(set) var nextCursor: String?
    private(set) var history: [WebhookHistoryEvent] = []
    private(set) var historyCursor: String?
    private(set) var historyID: String?
    private(set) var includesInactive = false
    private(set) var uncertainAction: String?
    private var uncertainBody: [String: JSON]?
    let account: String
    private let origin: String
    @ObservationIgnored private let service: any WebhookService
    @ObservationIgnored private let vault: WebhookEnrollmentVault
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    private var closed = false
    init(account: String, origin: String, service: any WebhookService, vault: WebhookEnrollmentVault, isCurrent: @escaping () -> Bool) { self.account = account; self.origin = origin; self.service = service; self.vault = vault; self.isCurrent = isCurrent }
    var current: Bool { !closed && isCurrent() }
    private func reviewID(_ d: WebhookDraft) -> String { d.origin + "|" + d.account + "|" + d.id }
    var secret: String? { current && pending.map { !WebhookSecretReviews.shared.finished.contains(reviewID($0.draft)) } == true && pending?.cancelling == false && pending?.draft.id == confirmed?.id && confirmed?.usable == true ? pending?.draft.secret : nil }
    func conceal() { confirmed = nil }
    func close() { closed = true; lease.cancel(); pending = nil; confirmed = nil; connections = []; history = []; uncertainBody = nil; uncertainAction = nil; message = nil }
    private func check() throws { try lease.check(); guard current else { throw CancellationError() } }
    private func perform(_ action: () async throws -> Void) async {
        guard current, !busy else { return }; busy = true; message = nil; defer { busy = false }
        do { try check(); try await action() } catch is CancellationError { } catch { if current {
            confirmed = nil
            if error is AccountSessionAuthorizationRequired {
                needsSignIn = true
                message = pending == nil ? "Sign in again to continue. Your tasks stay saved." : "Sign in again. Your setup is saved."
            } else { message = pending == nil ? "Action not confirmed. Reload to check its status." : "Action not confirmed. Your setup is saved." }
        } }
    }
    private func call(_ action: String, _ body: [String: JSON]) async throws -> [String: JSON] { try check(); let r = try await service.webhookReceipt(action:action,body:body,account:account,origin:origin); try check(); guard r["account"] == .string(account) else { throw WebhookValue.invalid }; needsSignIn = false; return r }
    private func connection(_ r: [String: JSON], id: String) throws -> WebhookConnection { guard case .object(let fields) = r["subscription"] else { throw WebhookValue.invalid }; let c = try WebhookConnection(fields); guard c.id == id else { throw WebhookValue.invalid }; return c }
    private func upsert(_ c: WebhookConnection) { if let n = connections.firstIndex(where:{$0.id == c.id}) { connections[n] = c } else { connections.insert(c,at:0) } }
    func load(more: Bool = false, includeInactive: Bool? = nil) async {
        await perform {
            self.pending = try await self.vault.recovery(account:self.account,origin:self.origin); try self.check(); self.confirmed = nil
            let cursor = more ? self.nextCursor : nil; guard !more || cursor != nil else { return }
            let inactive = includeInactive ?? self.includesInactive
            var body: [String: JSON] = ["limit":.number(25),"include_inactive":.bool(inactive)]; if let cursor { body["cursor"] = .string(cursor) }
            let r = try await self.call("list",body); guard case .array(let rows) = r["subscriptions"], rows.count <= 50 else { throw WebhookValue.invalid }
            let values = try rows.map { row -> WebhookConnection in guard case .object(let fields) = row else { throw WebhookValue.invalid }; return try WebhookConnection(fields) }
            let ids = values.map(\.id); guard Set(ids).count == ids.count, r["next_cursor"] == .null || (r["next_cursor"]?.text == ids.last && !ids.isEmpty), !more || Set(self.connections.map(\.id)).isDisjoint(with:ids) else { throw WebhookValue.invalid }
            self.connections = more ? self.connections + values : values; self.nextCursor = r["next_cursor"] == .null ? nil : r["next_cursor"]?.text; self.includesInactive = inactive
            if !more { self.uncertainAction = nil; self.uncertainBody = nil }
        }
    }
    func create(name: String, endpoint: String, scope: String, project: String?, events: Set<WebhookEvent>, days: Int) async {
        await perform {
            guard self.pending == nil else { throw WebhookValue.invalid }
            let draft = try WebhookDraft(account:self.account,origin:self.origin,name:name.trimmingCharacters(in:.whitespacesAndNewlines),endpoint:endpoint.trimmingCharacters(in:.whitespacesAndNewlines),scope:scope,project:project,events:events,days:days)
            let saved = try await self.vault.begin(draft,lease:self.lease); try self.check(); self.pending = saved
            guard !saved.cancelling, saved.draft.body == draft.body else { throw WebhookValue.invalid }; try await self.enroll(saved.draft)
        }
    }
    private func enroll(_ d: WebhookDraft) async throws {
        let r = try await call("create",d.body); let c = try connection(r,id:d.id)
        guard WebhookValue.sameReceiverOrigin(c.origin,d.endpoint), c.name == d.name, c.scope == d.scope, c.project == d.project, Set(c.events) == Set(d.events), abs(c.expires.timeIntervalSince(c.created)-Double(d.days)*86400) < 0.01 else { throw WebhookValue.invalid }
        let saved = try await vault.recovery(account:account,origin:origin); try check(); pending = saved
        guard saved?.draft.body == d.body, saved?.cancelling == false else { throw WebhookValue.invalid }; confirmed = c; upsert(c)
    }
    func resumeSetup() async { await perform { guard let p = self.pending else { return }; let saved = try await self.vault.recovery(account:self.account,origin:self.origin); try self.check(); self.pending = saved; guard saved?.draft.body == p.draft.body else { throw WebhookValue.invalid }; if saved?.cancelling == true { try await self.finishDiscard(p.draft) } else { try await self.enroll(p.draft) } } }
    func acknowledgeSaved() async { await perform { guard let p = self.pending, self.secret != nil else { throw WebhookValue.invalid }; self.confirmed = nil; try await self.vault.finish(p.draft,lease:self.lease); try self.check(); WebhookSecretReviews.shared.finished.insert(self.reviewID(p.draft)); self.pending = nil } }
    func discard() async { await perform { guard let p = self.pending else { return }; self.confirmed = nil; try await self.vault.cancel(p.draft,lease:self.lease); try self.check(); self.pending = WebhookRecovery(draft:p.draft,cancelling:true); try await self.finishDiscard(p.draft) } }
    private func finishDiscard(_ d: WebhookDraft) async throws { let r = try await call("cancel",["id":.string(d.id)]); guard r["id"] == .string(d.id), r["cancelled"] == .bool(true) else { throw WebhookValue.invalid }; try await vault.finish(d,lease:lease,cancelled:true); try check(); WebhookSecretReviews.shared.finished.insert(reviewID(d)); pending = nil; connections.removeAll{$0.id == d.id} }
    func control(_ action: String, connection c: WebhookConnection, event: WebhookHistoryEvent? = nil) async {
        await perform {
            guard self.uncertainAction == nil, ["verify","pause","resume","revoke","retry_delivery"].contains(action) else { throw WebhookValue.invalid }
            var b: [String: JSON] = ["id":.string(c.id)]
            if action == "verify" { b["attempt_id"] = .string(UUID().uuidString.lowercased()) }
            if ["pause","resume"].contains(action) { b["request_id"] = .string(UUID().uuidString.lowercased()); b["revision"] = .string(c.revision) }
            if action == "retry_delivery" { guard let event else { throw WebhookValue.invalid }; b["event_id"] = .string(event.id); b["request_id"] = .string(UUID().uuidString.lowercased()) }
            self.uncertainAction = action; self.uncertainBody = b; try await self.finishControl()
        }
    }
    func retryControl() async { await perform { try await self.finishControl() } }
    private func finishControl() async throws {
        guard let action = uncertainAction, let b = uncertainBody, let id = b["id"]?.text else { throw WebhookValue.invalid }
        let r = try await call(action,b), c = try connection(r,id:id)
        if ["pause","resume"].contains(action) { guard case .object(let command) = r["command"], command["request_id"] == b["request_id"], command["applied"] == .bool(true) else { throw WebhookValue.invalid } }
        if action == "revoke" { guard c.state == "revoked" else { throw WebhookValue.invalid } }
        if action == "verify" { guard case .object(let v) = r["verification"], v["attempt_id"] == b["attempt_id"], ["pending","verified","retry","refused","gone","expired","cancelled","unavailable"].contains(v["outcome"]?.text ?? "") else { throw WebhookValue.invalid }; if c.state != "active" { message = "The receiver did not confirm this connection. Check its secret and verification response before trying again." } }
        if action == "retry_delivery" { guard case .object(let retry) = r["retry"], retry["request_id"] == b["request_id"], retry["event_id"] == b["event_id"], retry["applied"] == .bool(true), case .object(let row) = r["event"] else { throw WebhookValue.invalid }; let e = try WebhookHistoryEvent(row); guard e.id == b["event_id"]?.text else { throw WebhookValue.invalid }; if let n = history.firstIndex(where:{$0.id == e.id}) { history[n] = e } }
        upsert(c); uncertainAction = nil; uncertainBody = nil
        if action == "revoke", let d = pending?.draft, d.id == c.id { confirmed = nil; WebhookSecretReviews.shared.finished.insert(reviewID(d)); try await vault.finish(d,lease:lease,cancelled:true); try check(); pending = nil }
    }
    func loadHistory(_ c: WebhookConnection, more: Bool = false) async {
        await perform {
            let cursor = more && self.historyID == c.id ? self.historyCursor : nil; guard !more || cursor != nil else { return }
            var body: [String: JSON] = ["id":.string(c.id),"limit":.number(25)]; if let cursor { body["cursor"] = .string(cursor) }
            let r = try await self.call("history",body), current = try self.connection(r,id:c.id)
            guard case .array(let rows) = r["events"], rows.count <= 50 else { throw WebhookValue.invalid }
            let values = try rows.map { v -> WebhookHistoryEvent in guard case .object(let row) = v else { throw WebhookValue.invalid }; return try WebhookHistoryEvent(row) }
            let ids = values.map(\.id); guard Set(ids).count == ids.count, r["next_cursor"] == .null || r["next_cursor"]?.text == ids.last && !ids.isEmpty, !more || Set(self.history.map(\.id)).isDisjoint(with:ids) else { throw WebhookValue.invalid }
            self.history = more ? self.history + values : values; self.historyID = c.id; self.historyCursor = r["next_cursor"] == .null ? nil : r["next_cursor"]?.text; self.upsert(current)
        }
    }
}
