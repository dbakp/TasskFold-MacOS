import Foundation
import Observation

/// A reviewed move is deliberately separate from ordinary task editing. The
/// durable request contains identities and a server proof, never task text.
struct TeamTaskMoveScope: Equatable, Sendable {
    let account: String, origin: String, team: String, task: String, generation: String, source: String, destination: String
    let undoes: String?
    init(account: String, origin: String, team: String, task: String, generation: String, source: String, destination: String, undoes: String? = nil) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard [team, task, generation, source, destination].allSatisfy(TeamProjectValue.id), source != destination,
              undoes == nil || TeamProjectValue.id(undoes!) else { throw TeamTaskMoveCommand.invalid }
        self.account = account; self.origin = origin; self.team = team; self.task = task; self.generation = generation
        self.source = source; self.destination = destination; self.undoes = undoes
    }
    var body: [String: JSON] {
        var result: [String: JSON] = ["team_id": .string(team), "task_id": .string(task), "task_generation": .string(generation), "source_project_id": .string(source), "destination_project_id": .string(destination)]
        if let undoes { result["undoes"] = .string(undoes) }; return result
    }
    var reviewOperation: String { undoes == nil ? "review" : "review_undo" }
    var operation: String { undoes == nil ? "move" : "undo" }
}

struct TeamTaskMoveReview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let scope: TeamTaskMoveScope
    let token: String, expiresText: String, sourceName: String, destinationName: String
    let expires: Date, task: Record, visibility: TeamProjectVisibility
    let clearedAssignments: Int, restoredAssignments: Int, discussionCount: Int
    var description: String { "Private task move review" }; var debugDescription: String { description }
    init(_ raw: [String: JSON], scope: TeamTaskMoveScope) throws {
        guard raw["move_review_protocol"] == .number(1), raw["account"] == .string(scope.account),
              scope.body.filter({ $0.key != "undoes" }).allSatisfy({ raw[$0.key] == $0.value }),
              raw["related_request"] == (scope.undoes.map(JSON.string) ?? .null),
              case .string(let token)? = raw["review_token"], Self.validToken(token),
              case .string(let expiresText)? = raw["expires_at"], Self.validDate(expiresText),
              case .object(let fields)? = raw["task"], fields["id"] == .string(scope.task), fields["task_generation"] == .string(scope.generation), fields["project_id"] == .string(scope.source),
              case .string(let visibility)? = raw["destination_visibility"], let visibility = TeamProjectVisibility(rawValue: visibility),
              try JSONEncoder().encode(fields).count <= 128_000 else { throw TeamTaskMoveCommand.invalid }
        _ = try TeamOrganizationValue.id(fields["user_id"])
        guard case .string(let title)? = fields["title"], title.utf8.count <= 120_000 else { throw TeamTaskMoveCommand.invalid }
        try TeamChecklist.validate(fields["subtasks"] ?? .array([]))
        self.scope = scope; self.token = token; self.expiresText = expiresText; expires = try TeamOrganizationValue.date(.string(expiresText))
        sourceName = try TeamOrganizationValue.name(raw["source_name"]); destinationName = try TeamOrganizationValue.name(raw["destination_name"])
        task = Record(fields); self.visibility = visibility
        clearedAssignments = try Self.count(raw["cleared_assignments"], limit: 1001)
        restoredAssignments = try Self.count(raw["restored_assignments"], limit: 1001)
        discussionCount = try Self.count(raw["discussion_count"], limit: 500)
    }
    private static func count(_ value: JSON?, limit: Double) throws -> Int {
        guard case .number(let n)? = value, n.isFinite, n >= 0, n <= limit, n.rounded(.down) == n else { throw TeamTaskMoveCommand.invalid }; return Int(n)
    }
    static func validToken(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func validDate(_ value: String) -> Bool { value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil }
}

struct TeamTaskMoveCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "team-task-move-v1."
    static var invalid: AppFailure { AppFailure(message: "Review this task move again before sending it.") }
    let scope: TeamTaskMoveScope
    let body: [String: JSON]
    var account: String { scope.account }; var origin: String { scope.origin }
    var id: String { body["request_id"]!.text }; var operation: String { scope.operation }
    var description: String { "Private task move request" }; var debugDescription: String { description }
    init(review: TeamTaskMoveReview, requestID: UUID = UUID(), now: Date = Date()) throws {
        guard review.expires > now, review.expires <= now.addingTimeInterval(31 * 60) else { throw Self.invalid }
        var body = review.scope.body
        body["request_id"] = .string(requestID.uuidString.lowercased()); body["review_token"] = .string(review.token); body["expires_at"] = .string(review.expiresText)
        try self.init(account: review.scope.account, origin: review.scope.origin, body: body)
    }
    init(account: String, origin: String, body: [String: JSON]) throws {
        scope = try TeamTaskMoveScope(account: account, origin: origin, team: TeamOrganizationValue.id(body["team_id"]), task: TeamOrganizationValue.id(body["task_id"]), generation: TeamOrganizationValue.id(body["task_generation"]), source: TeamOrganizationValue.id(body["source_project_id"]), destination: TeamOrganizationValue.id(body["destination_project_id"]), undoes: body["undoes"].map { try TeamOrganizationValue.id($0) })
        guard Set(body.keys) == Set(scope.body.keys).union(["request_id", "review_token", "expires_at"]),
              case .string(let token)? = body["review_token"], TeamTaskMoveReview.validToken(token),
              case .string(let expires)? = body["expires_at"], TeamTaskMoveReview.validDate(expires),
              try JSONEncoder().encode(body).count <= 16_384 else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["request_id"]); _ = try TeamOrganizationValue.date(body["expires_at"]); self.body = body
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(body, forKey: .body)
    }
    func confirmed(_ raw: [String: JSON]) throws -> TeamTaskMoveReceipt {
        guard raw["protocol"] == .number(1), raw["account"] == .string(account), raw["request_id"] == body["request_id"], raw["operation"] == .string(operation),
              scope.body.filter({ $0.key != "undoes" }).allSatisfy({ raw[$0.key] == $0.value }),
              raw["related_request"] == (scope.undoes.map(JSON.string) ?? .null), case .bool(let replayed)? = raw["replayed"] else { throw Self.invalid }
        let task: Record?
        if raw["task"] == .null { guard replayed else { throw Self.invalid }; task = nil }
        else {
            guard case .object(let fields)? = raw["task"], fields["id"] == .string(scope.task), fields["task_generation"] == .string(scope.generation), fields["project_id"] == .string(scope.destination),
                  try JSONEncoder().encode(fields).count <= 128_000 else { throw Self.invalid }
            _ = try TeamOrganizationValue.id(fields["user_id"])
            guard case .string? = fields["title"] else { throw Self.invalid }
            try TeamChecklist.validate(fields["subtasks"] ?? .array([])); task = Record(fields)
        }
        return TeamTaskMoveReceipt(command: self, task: task, replayed: replayed, raw: raw)
    }
}
struct TeamTaskMoveReceipt: Equatable, Sendable {
    let command: TeamTaskMoveCommand, task: Record?, replayed: Bool
    let raw: [String: JSON]
    func inverseScope() throws -> TeamTaskMoveScope {
        let s = command.scope
        return try TeamTaskMoveScope(account: s.account, origin: s.origin, team: s.team, task: s.task, generation: s.generation, source: s.destination, destination: s.source, undoes: command.id)
    }
}
typealias TeamTaskMoveVault = ReviewedTeamCommandVault<TeamTaskMoveCommand>
@MainActor protocol TeamTaskMoveService: AnyObject {
    func teamTaskMoveReview(_ scope: TeamTaskMoveScope) async throws -> TeamTaskMoveReview
    func teamTaskMove(_ command: TeamTaskMoveCommand) async throws -> TeamTaskMoveReceipt
}
extension Backend: TeamTaskMoveService {}

/// A lost reply retains exactly the same nonce across windows and launches.
/// Retrying after review expiry is allowed: the service may acknowledge an
/// already accepted request, but refuses a first application of an expired one.
@MainActor @Observable final class TeamTaskMoveModel {
    private(set) var pending: TeamTaskMoveCommand?
    private(set) var receipt: TeamTaskMoveReceipt?
    private(set) var busy = false
    private(set) var message: String?
    let account: String, origin: String
    @ObservationIgnored private let vault: TeamTaskMoveVault
    @ObservationIgnored private let service: any TeamTaskMoveService
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    private var closed = false
    init(account: String, origin: String, vault: TeamTaskMoveVault, service: any TeamTaskMoveService, isCurrent: @escaping () -> Bool) {
        self.account = account; self.origin = origin; self.vault = vault; self.service = service; self.isCurrent = isCurrent
    }
    private func check() throws { try lease.check(); guard !closed, isCurrent() else { throw CancellationError() } }
    func close() { closed = true; lease.cancel(); pending = nil; receipt = nil; message = nil }
    private func recover() async throws { let saved = try await vault.pending(account: account, origin: origin); try check(); pending = saved }
    func load() async { await perform { try await self.recover() } }
    func send(_ command: TeamTaskMoveCommand, now: Date = Date()) async {
        await perform {
            try await self.recover()
            let expires = try TeamOrganizationValue.date(command.body["expires_at"])
            guard command.account == self.account, command.origin == self.origin, self.pending == nil, expires > now, expires <= now.addingTimeInterval(31 * 60) else { throw TeamTaskMoveCommand.invalid }
            try await self.vault.begin(command, lease: self.lease); try self.check(); self.pending = command; try await self.finish(command)
        }
    }
    func retry() async {
        guard let reviewed = pending else { return }
        await perform { try await self.recover(); guard self.pending == reviewed else { throw TeamTaskMoveCommand.invalid }; try await self.finish(reviewed) }
    }
    func clearReviewedRequest(_ reviewed: TeamTaskMoveCommand) async {
        await perform { try await self.recover(); guard self.pending == reviewed else { throw TeamTaskMoveCommand.invalid }; try await self.vault.clear(reviewed, lease: self.lease); try self.check(); try await self.recover() }
    }
    private func finish(_ command: TeamTaskMoveCommand) async throws {
        try check(); let result = try await service.teamTaskMove(command); try check()
        // Revalidate the peer's typed result too; a substitute service cannot
        // return a different command or task projection to this model.
        guard try command.confirmed(result.raw) == result else { throw TeamTaskMoveCommand.invalid }
        try await vault.clear(command, lease: lease); try check(); pending = nil; receipt = result; try await recover()
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !closed, isCurrent(), !busy else { return }
        busy = true; message = nil; receipt = nil; defer { busy = false }
        do { try check(); try await action(); try check() }
        catch { guard !closed, isCurrent() else { return }; message = pending == nil ? "The task move couldn’t be prepared. Review it again." : "The result couldn’t be confirmed. Your saved move is kept. Retry it or review the latest project before clearing the request. Clearing does not undo a move." }
    }
}
