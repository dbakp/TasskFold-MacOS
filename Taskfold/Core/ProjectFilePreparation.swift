import Foundation
import Observation

/// Persisted before networking. Never contains file bytes or provider identities.
struct ProjectFilePreparationRequest: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "project-file-preparation-v1."
    static let maximumStoredBytes = 20_000
    static var invalid: AppFailure { AppFailure(message: "Review these project files again. Your originals are kept.") }
    let account: String, origin: String, body: [String: JSON], expectedCount: Int
    let scope: TeamProjectAdoptionScope
    var id: String { body["request_id"]!.text }
    var inspectionToken: String { body["inspection_token"]!.text }
    var description: String { "Private project file preparation" }
    var debugDescription: String { description }
    init(_ inspection: TeamProjectAdoptionInspection, requestID: UUID = UUID()) throws {
        guard inspection.filePreparationSupported, let files = inspection.fileInventory, files.stored > 0, files.legacy == 0, files.unavailable == 0 else { throw Self.invalid }
        try self.init(account: inspection.scope.account, origin: inspection.scope.origin, body: ["request_id": .string(requestID.uuidString.lowercased()), "scope": .object(inspection.scope.body), "inspection_token": .string(inspection.token)], expectedCount: files.stored)
    }
    init(account: String, origin: String, body: [String: JSON], expectedCount: Int) throws {
        guard Set(body.keys) == ["request_id", "scope", "inspection_token"], TeamProjectValue.id(body["request_id"]?.text ?? ""),
              TeamTaskMoveReview.validToken(body["inspection_token"]?.text ?? ""), case .object(let fields)? = body["scope"],
              Set(fields.keys) == ["team_id", "roots", "visibility", "folder_id", "parent_id"],
              let visibility = TeamProjectVisibility(rawValue: fields["visibility"]?.text ?? ""), (1...10000).contains(expectedCount) else { throw Self.invalid }
        scope = try TeamProjectAdoptionScope(account: account, origin: origin, team: TeamOrganizationValue.id(fields["team_id"]), roots: TeamProjectAdoptionValue.ids(fields["roots"], limit: 100), visibility: visibility, folder: TeamProjectValue.optionalID(fields["folder_id"]), parent: TeamProjectValue.optionalID(fields["parent_id"]))
        guard fields == scope.body, try TaskfoldJSONEncoder().encode(body).count <= Self.maximumStoredBytes - 1024 else { throw Self.invalid }
        self.account = account; self.origin = origin; self.body = body; self.expectedCount = expectedCount
    }
    private enum CodingKeys: CodingKey { case account, origin, body, expectedCount }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), expectedCount: c.decode(Int.self, forKey: .expectedCount)) }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(body, forKey: .body); try c.encode(expectedCount, forKey: .expectedCount) }
    func matches(_ inspection: TeamProjectAdoptionInspection) -> Bool { scope == inspection.scope && inspectionToken == inspection.token && expectedCount == inspection.fileInventory?.stored && inspection.fileInventory?.legacy == 0 && inspection.fileInventory?.unavailable == 0 }
}

typealias ProjectFilePreparationVault = ReviewedTeamCommandVault<ProjectFilePreparationRequest>
struct ProjectFilePreparationPage: Equatable, Sendable, CustomStringConvertible {
    enum State: String, Sendable { case preparing, ready, cancelled, expired, committed }
    struct Item: Equatable, Sendable, Identifiable {
        enum Phase: String, Sendable { case waiting, reserved, ready }
        let id: String, label: String, bytes: Int, type: String, phase: Phase
    }
    let request: ProjectFilePreparationRequest, id: String, state: State, total: Int, prepared: Int, expires: Date
    let items: [Item], next: String?, after: String?
    var description: String { "Private project file progress" }
    init(_ raw: [String: JSON], request: ProjectFilePreparationRequest, plan: String? = nil, after: String? = nil) throws {
        guard Set(raw.keys) == ["protocol", "plan_id", "request_id", "scope", "state", "total", "prepared", "expires_at", "items", "next", "project_transferred"],
              raw["protocol"] == .number(1), raw["request_id"] == request.body["request_id"], raw["scope"] == .object(request.scope.body),
              let state = State(rawValue: raw["state"]?.text ?? ""), raw["project_transferred"] == .bool(state == .committed) else { throw ProjectFilePreparationRequest.invalid }
        id = try TeamOrganizationValue.id(raw["plan_id"])
        guard plan == nil || plan == id, after == nil || TeamProjectValue.id(after!) else { throw ProjectFilePreparationRequest.invalid }
        total = try TeamProjectAdoptionValue.count(raw["total"], limit: 10000); prepared = try TeamProjectAdoptionValue.count(raw["prepared"], limit: total)
        guard total == request.expectedCount || (state == .cancelled && total == 0), ![.ready, .committed].contains(state) || prepared == total else { throw ProjectFilePreparationRequest.invalid }
        expires = try TeamProjectAdoptionValue.date(raw["expires_at"])
        items = try TeamOrganizationValue.rows(raw["items"], limit: 100).map { row in
            guard Set(row.keys) == ["operation_id", "label", "byte_count", "type", "state"], case .string(let label)? = row["label"], !label.isEmpty, label.count <= 240, label.utf8.count <= 960,
                  !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), case .string(let type)? = row["type"], TaskFileUploadJournal.types.contains(type),
                  let phase = Item.Phase(rawValue: row["state"]?.text ?? ""), ![.ready, .committed].contains(state) || phase == .ready else { throw ProjectFilePreparationRequest.invalid }
            let bytes = try TeamProjectAdoptionValue.count(row["byte_count"], limit: TaskFileUploadJournal.maximumBytes); guard bytes > 0 else { throw ProjectFilePreparationRequest.invalid }
            return try Item(id: TeamOrganizationValue.id(row["operation_id"]), label: label, bytes: bytes, type: type, phase: phase)
        }
        next = try TeamProjectValue.optionalID(raw["next"])
        guard items.count <= total, Set(items.map(\.id)).count == items.count, items.map(\.id) == items.map(\.id).sorted(),
              items.allSatisfy({ after == nil || $0.id > after! }), next == nil || (items.count == 100 && next == items.last?.id),
              prepared >= items.filter({ $0.phase == .ready }).count, total - prepared >= items.filter({ $0.phase != .ready }).count,
              total != 0 || (items.isEmpty && next == nil) else { throw ProjectFilePreparationRequest.invalid }
        self.request = request; self.state = state; self.after = after
    }
}
struct ProjectFileConsent: Equatable, Sendable, Codable, CustomStringConvertible {
    let plan: String, count: Int, bytes: Int
    let request: ProjectFilePreparationRequest
    var description: String { "Reviewed private-copy file policy" }
    var policy: JSON { .object(["protocol": .number(1), "plan_id": .string(plan), "action": .string("share_copies_keep_originals")]) }
    var receipt: JSON { .object(["protocol": .number(1), "plan_id": .string(plan), "action": .string("share_copies_keep_originals"), "count": .number(Double(count)), "byte_count": .number(Double(bytes)), "originals_kept_private": .bool(true)]) }
    init(plan: String, count: Int, bytes: Int, request: ProjectFilePreparationRequest) throws { guard count == request.expectedCount, TeamProjectValue.id(plan), (1...10000).contains(count), bytes >= count, bytes <= min(1_073_741_824, count * TaskFileUploadJournal.maximumBytes) else { throw ProjectFilePreparationRequest.invalid }; self.plan = plan; self.count = count; self.bytes = bytes; self.request = request }
    init(pages: [ProjectFilePreparationPage]) throws {
        guard let first = pages.first, first.state == .ready, first.after == nil else { throw ProjectFilePreparationRequest.invalid }
        var previous: String?, seen: Set<String> = [], count = 0, bytes = 0
        for (index, page) in pages.enumerated() {
            guard (index == 0 || previous != nil), page.request == first.request, page.id == first.id, page.state == .ready, page.total == first.total, page.prepared == first.prepared, page.expires == first.expires, page.after == previous else { throw ProjectFilePreparationRequest.invalid }
            for item in page.items { guard seen.insert(item.id).inserted else { throw ProjectFilePreparationRequest.invalid }; count += 1; bytes += item.bytes }
            previous = page.next
        }
        guard previous == nil, count == first.total, pages.count <= 100 else { throw ProjectFilePreparationRequest.invalid }
        try self.init(plan: first.id, count: count, bytes: bytes, request: first.request)
    }
    func validateReview(_ raw: JSON?) throws {
        guard case .object(var fields)? = raw, Set(fields.keys) == Set(receipt.object.keys).union(["inventory_token"]), let token = fields.removeValue(forKey: "inventory_token"), TeamTaskMoveReview.validToken(token.text), .object(fields) == receipt else { throw ProjectFilePreparationRequest.invalid }
    }
    private enum CodingKeys: CodingKey { case plan, count, bytes, request }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(plan: c.decode(String.self, forKey: .plan), count: c.decode(Int.self, forKey: .count), bytes: c.decode(Int.self, forKey: .bytes), request: c.decode(ProjectFilePreparationRequest.self, forKey: .request)) }
}

@MainActor protocol ProjectFilePreparationService: AnyObject {
    func projectFilePreparation(_ request: ProjectFilePreparationRequest, action: ProjectFilePreparationAction, incarnation: UUID) async throws -> ProjectFilePreparationPage?
}
enum ProjectFilePreparationAction: Equatable, Sendable {
    case prepare, resolve, cancelRequest, copy(plan: String, operation: String), check(plan: String, after: String?)
    var name: String { switch self { case .prepare: "prepare"; case .resolve: "resolve"; case .cancelRequest: "cancel_request"; case .copy: "copy"; case .check: "check" } }
    func body(_ request: ProjectFilePreparationRequest) throws -> [String: JSON] {
        switch self {
        case .prepare, .resolve, .cancelRequest: return request.body
        case .copy(let plan, let operation): guard TeamProjectValue.id(plan), TeamProjectValue.id(operation) else { throw ProjectFilePreparationRequest.invalid }; return ["plan_id": .string(plan), "operation_id": .string(operation)]
        case .check(let plan, let after): guard TeamProjectValue.id(plan), after == nil || TeamProjectValue.id(after!) else { throw ProjectFilePreparationRequest.invalid }; return ["plan_id": .string(plan), "after": after.map(JSON.string) ?? .null]
        }
    }
}

/// The immutable request remains in secure storage through every lost response.
@MainActor @Observable final class ProjectFilePreparationModel {
    private(set) var request: ProjectFilePreparationRequest?
    private(set) var pages: [ProjectFilePreparationPage] = []
    private(set) var busy = false
    private(set) var paused = false
    private(set) var recoveryLoaded = false
    private(set) var message: String?
    var consent: ProjectFileConsent? { guard !closed, current(), !busy, !paused, request == pages.first?.request, let expires = page?.expires, expires > Date() else { return nil }; return try? ProjectFileConsent(pages: pages) }
    var page: ProjectFilePreparationPage? { pages.first }
    @ObservationIgnored private let vault: ProjectFilePreparationVault
    @ObservationIgnored private let service: any ProjectFilePreparationService
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    private let account: String, origin: String, incarnation: UUID
    private var closed = false
    private var run = UUID()
    init(account: String, origin: String, incarnation: UUID, vault: ProjectFilePreparationVault, service: any ProjectFilePreparationService, current: @escaping () -> Bool) { self.account = account; self.origin = origin; self.incarnation = incarnation; self.vault = vault; self.service = service; self.current = current }
    func close() { closed = true; run = UUID(); busy = false; paused = true; lease.cancel(); request = nil; pages = []; message = nil; recoveryLoaded = false }
    func stop() {
        guard !closed, busy else { return }
        // A request may finish on the server after Stop. Its immutable identity
        // is retained for reconciliation, but it no longer owns this screen.
        run = UUID(); busy = false; paused = true
        message = "Preparation paused. Files remain private; continue when you’re ready."
    }
    func consent(for inspection: TeamProjectAdoptionInspection) -> ProjectFileConsent? {
        guard inspection.filePreparationSupported, request?.matches(inspection) == true else { return nil }
        return consent
    }
    private func check(_ id: UUID) throws { try Task.checkCancellation(); try lease.check(); guard !closed, current(), run == id else { throw CancellationError() } }
    private func recover(_ id: UUID) async throws { recoveryLoaded = false; let saved = try await vault.pending(account: account, origin: origin); try check(id); if request != saved { pages = [] }; request = saved; recoveryLoaded = true }
    func load() async { await perform { id in try await self.recover(id); if let request = self.request { try await self.resolve(request, id: id) } } }
    func prepare(_ inspection: TeamProjectAdoptionInspection) async {
        await perform { id in
            try await self.recover(id); guard self.request == nil, inspection.scope.account == self.account, inspection.scope.origin == self.origin else { throw ProjectFilePreparationRequest.invalid }
            let request = try ProjectFilePreparationRequest(inspection); try await self.vault.begin(request, lease: self.lease); try self.check(id); self.request = request
            try await self.copy(request, id: id)
        }
    }
    func resume() async { await perform { id in try await self.recover(id); guard let request = self.request else { return }; try await self.copy(request, id: id) } }
    func cancel() async {
        await perform { id in
            try await self.recover(id); guard let request = self.request else { return }
            let knownPlan = self.page?.id
            guard let page = try await self.service.projectFilePreparation(request, action: .cancelRequest, incarnation: self.incarnation), page.request == request, page.state == .cancelled, knownPlan == nil || knownPlan == page.id else { throw ProjectFilePreparationRequest.invalid }
            try self.check(id); try await self.vault.clear(request, lease: self.lease); try self.check(id); self.request = nil; self.pages = []; self.message = "Preparation cancelled. Original files are unchanged."
        }
    }
    func clearCommitted() async {
        await perform { id in
            try await self.recover(id); guard let request = self.request else { return }; try await self.resolve(request, id: id)
            guard self.page?.state == .committed else { throw ProjectFilePreparationRequest.invalid }
            try await self.vault.clear(request, lease: self.lease); try self.check(id); self.request = nil; self.pages = []
        }
    }
    private func resolve(_ request: ProjectFilePreparationRequest, id: UUID) async throws {
        let first = try await service.projectFilePreparation(request, action: .resolve, incarnation: incarnation); try check(id)
        guard let first else { pages = []; return }; try await collect(first, id: id)
    }
    private func collect(_ first: ProjectFilePreparationPage, id: UUID) async throws {
        guard first.request == request, first.after == nil else { throw ProjectFilePreparationRequest.invalid }
        var result = [first], next = first.next
        while let cursor = next {
            guard result.count < 100, let page = try await service.projectFilePreparation(first.request, action: .check(plan: first.id, after: cursor), incarnation: incarnation) else { throw ProjectFilePreparationRequest.invalid }
            try check(id); guard page.id == first.id, page.request == first.request, page.after == cursor, page.total == first.total, page.state == first.state else { throw ProjectFilePreparationRequest.invalid }
            result.append(page); next = page.next
        }
        guard result.flatMap(\.items).count == first.total, Set(result.flatMap(\.items).map(\.id)).count == first.total else { throw ProjectFilePreparationRequest.invalid }
        pages = result
    }
    private func copy(_ request: ProjectFilePreparationRequest, id: UUID) async throws {
        guard let first = try await service.projectFilePreparation(request, action: .prepare, incarnation: incarnation) else { throw ProjectFilePreparationRequest.invalid }
        try check(id); try await collect(first, id: id)
        guard first.state == .preparing else { return }
        let work = pages.flatMap(\.items).filter { $0.phase != .ready }
        for item in work {
            try check(id)
            guard let page = try await service.projectFilePreparation(request, action: .copy(plan: first.id, operation: item.id), incarnation: incarnation) else { throw ProjectFilePreparationRequest.invalid }
            try check(id); guard page.id == first.id, page.request == request else { throw ProjectFilePreparationRequest.invalid }
            if page.state != .preparing { try await collect(page, id: id); return }
            // Progress replies contain the first page. Do not reload a whole
            // large manifest for every file: initial and final paging suffice.
            pages = [page]
        }
        try await resolve(request, id: id)
    }
    private func perform(_ action: (UUID) async throws -> Void) async {
        guard !closed, current(), !busy else { return }; let id = UUID(); run = id; busy = true; paused = false; message = nil
        defer { if run == id { busy = false } }
        do { try check(id); try await action(id); try check(id) }
        catch { guard !closed, current(), run == id else { return }; pages = []; message = request == nil ? "File preparation couldn’t start. Check this device’s saved request storage and try again. Original files remain unchanged." : "File preparation couldn’t be confirmed. Your exact request is saved; retry or cancel it. Original files remain unchanged." }
    }
}
