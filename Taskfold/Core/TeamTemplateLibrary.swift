import Foundation
import Observation

enum TeamTemplateLibraryValue {
    static var invalid: AppFailure { AppFailure(message: "Team templates couldn’t be verified. Refresh to try again.") }
    static func revision(_ raw: JSON?, zero: Bool = false) throws -> Double {
        guard case .number(let value)? = raw, value.isFinite, value.rounded(.down) == value,
              value >= (zero ? 0 : 1), value <= 9_007_199_254_740_991 else { throw invalid }
        return value
    }
    static func documentBytes(_ document: JSON) throws -> Int {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(document).count
    }
    static func name(_ raw: JSON?) throws -> String {
        guard case .string(let value)? = raw, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= 160, value.utf8.count <= 640,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { throw invalid }
        return value
    }
}

/// Scope and capability are re-read from the service; a directory role alone is
/// never authority to display a template or offer a library mutation.
struct TeamTemplateLibraryScope: Equatable, Sendable {
    let account: String, origin: String, team: String
    let role: TeamOrganizationRole
    let archived: Bool, canManage: Bool
    init(_ raw: [String: JSON], account: String, origin: String, team: String) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard TeamProjectValue.id(team), raw["library_protocol"] == .number(1), raw["account"] == .string(account), raw["team_id"] == .string(team),
              case .string(let text)? = raw["role"], let role = TeamOrganizationRole(rawValue: text), role != .guest,
              [JSON.string("active"), .string("archived")].contains(raw["team_state"]),
              case .bool(let manage)? = raw["can_manage"] else { throw TeamTemplateLibraryValue.invalid }
        let archived = raw["team_state"] == .string("archived")
        guard manage == (!archived && role.directoryVisible) else { throw TeamTemplateLibraryValue.invalid }
        self.account = account; self.origin = origin; self.team = team; self.role = role; self.archived = archived; canManage = manage
    }
}

struct TeamTemplateMetadata: Equatable, Identifiable, Sendable {
    let id: String, name: String
    let revision: Double
    let created: Date, updated: Date
    init(_ raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["id", "name", "revision", "created_at", "updated_at"] else { throw TeamTemplateLibraryValue.invalid }
        id = try TeamOrganizationValue.id(raw["id"]); name = try TeamTemplateLibraryValue.name(raw["name"])
        revision = try TeamTemplateLibraryValue.revision(raw["revision"])
        created = try TeamOrganizationValue.date(raw["created_at"]); updated = try TeamOrganizationValue.date(raw["updated_at"])
    }
}

struct TeamTemplatePage: Equatable, Sendable {
    let scope: TeamTemplateLibraryScope
    let revision: Double
    let items: [TeamTemplateMetadata]
    let next: String?
    init(_ raw: [String: JSON], account: String, origin: String, team: String, after: String? = nil, revision expected: Double? = nil) throws {
        guard Set(raw.keys) == ["library_protocol", "account", "team_id", "team_state", "role", "can_manage", "library_revision", "items", "next_cursor"],
              after == nil || TeamProjectValue.id(after!), after == nil || expected != nil else { throw TeamTemplateLibraryValue.invalid }
        scope = try .init(raw, account: account, origin: origin, team: team)
        revision = try TeamTemplateLibraryValue.revision(raw["library_revision"], zero: true)
        guard expected == nil || expected == revision else { throw TeamTemplateLibraryValue.invalid }
        items = try TeamOrganizationValue.rows(raw["items"], limit: 50).map(TeamTemplateMetadata.init)
        try TeamOrganizationValue.unique(items, by: \.id)
        guard items.map(\.id) == items.map(\.id).sorted(), items.allSatisfy({ after == nil || $0.id > after! }),
              revision > 0 || items.isEmpty else { throw TeamTemplateLibraryValue.invalid }
        if raw["next_cursor"] == .null { next = nil }
        else {
            next = try TeamOrganizationValue.id(raw["next_cursor"])
            guard items.count == 50, next == items.last?.id else { throw TeamTemplateLibraryValue.invalid }
        }
    }
}

/// Opaque documents remain intact. Only the full current workflow validator may
/// authorize preview/use/edit; future and malformed definitions are read-only.
struct TeamTemplateDetail: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let scope: TeamTemplateLibraryScope
    let metadata: TeamTemplateMetadata
    let document: JSON
    var supported: WorkflowTemplate? { try? WorkflowTemplate(document: document) }
    var description: String { "Private team template definition" }
    var debugDescription: String { description }
    init(_ raw: [String: JSON], account: String, origin: String, team: String, template: String) throws {
        guard TeamProjectValue.id(template), Set(raw.keys) == ["library_protocol", "account", "team_id", "team_state", "role", "can_manage", "item"],
              case .object(var item)? = raw["item"], let document = item.removeValue(forKey: "document"), case .object(let root) = document,
              try TeamTemplateLibraryValue.documentBytes(document) <= 2_000_000 else { throw TeamTemplateLibraryValue.invalid }
        _ = try TeamTemplateLibraryValue.revision(root["version"])
        scope = try .init(raw, account: account, origin: origin, team: team); metadata = try .init(item)
        guard metadata.id == template else { throw TeamTemplateLibraryValue.invalid }
        self.document = document
    }
}

/// The complete catalog is published once, after pagination and a workspace
/// boundary check. Invalidation drops names and definitions synchronously.
@MainActor @Observable final class TeamTemplateBrowser {
    private(set) var items: [TeamTemplateMetadata] = []
    private(set) var scope: TeamTemplateLibraryScope?
    private(set) var detail: TeamTemplateDetail?
    private(set) var organization: TeamOrganizationDetail?
    private(set) var loading = false
    private(set) var message: String?
    private var attempt = UUID()
    private let account: String, origin: String, teamID: String
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let fence: () async throws -> String
    @ObservationIgnored private let page: (String?, Double?) async throws -> TeamTemplatePage
    @ObservationIgnored private let readTeam: (() async throws -> TeamOrganizationDetail)?
    @ObservationIgnored private let readDetail: (String) async throws -> TeamTemplateDetail
    init(account: String, origin: String, team: String, current: @escaping () -> Bool, fence: @escaping () async throws -> String, page: @escaping (String?, Double?) async throws -> TeamTemplatePage, detail: @escaping (String) async throws -> TeamTemplateDetail, readTeam: (() async throws -> TeamOrganizationDetail)? = nil) {
        self.account = account; self.origin = origin; self.teamID = team; self.readTeam = readTeam; self.current = current; self.fence = fence; self.page = page; readDetail = detail
    }
    func invalidate() { attempt = UUID(); items = []; scope = nil; detail = nil; organization = nil; loading = false; message = nil }
    func refresh(template: String? = nil) async {
        invalidate(); guard current() else { return }; let id = attempt; loading = true
        func check() throws { guard id == attempt, current() else { throw CancellationError() } }
        do {
            let before = try await fence(); try check()
            guard before.utf8.count == 64, before.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw TeamTemplateLibraryValue.invalid }
            let organization = try await readTeam?(); try check()
            var rows: [TeamTemplateMetadata] = [], selected: TeamTemplateDetail?, scope: TeamTemplateLibraryScope?
            if let template {
                selected = try await readDetail(template); try check()
                guard selected?.metadata.id == template else { throw TeamTemplateLibraryValue.invalid }; scope = selected?.scope
            } else {
                var cursor: String?, revision: Double?
                repeat {
                    let result = try await page(cursor, revision); try check()
                    guard (scope == nil || scope == result.scope), revision == nil || revision == result.revision,
                          result.items.allSatisfy({ cursor == nil || $0.id > cursor! }), rows.count + result.items.count <= 200 else { throw TeamTemplateLibraryValue.invalid }
                    scope = result.scope; revision = result.revision; rows += result.items
                    guard result.next == nil || (result.next == result.items.last?.id && result.next != cursor && rows.count < 200) else { throw TeamTemplateLibraryValue.invalid }
                    cursor = result.next
                } while cursor != nil
                try TeamOrganizationValue.unique(rows, by: \.id)
            }
            guard let scope, scope.account == account, scope.origin == origin, scope.team == teamID else { throw TeamTemplateLibraryValue.invalid }
            if let organization {
                guard organization.account == account, organization.origin == origin, organization.team.id == teamID, organization.team.role == scope.role, organization.team.archived == scope.archived else { throw TeamTemplateLibraryValue.invalid }
            }
            let after = try await fence(); try check(); guard before == after else { throw TeamWorkspaceChanged() }
            self.scope = scope; items = rows; detail = selected; self.organization = organization
        } catch {
            guard id == attempt else { return }
            if current() { message = error is AccountSessionAuthorizationRequired ? "Sign in again to view team templates." : "Team templates couldn’t be refreshed. Try again when you’re connected." }
        }
        if id == attempt { loading = false }
    }
}

extension Backend {
    private func teamTemplateRead(_ operation: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] {
        guard session?.user.id == account, TeamProjectValue.id(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let context = try reauthenticationContext(account: account)
        let data = try await request("/rest/v1/rpc/taskfold_team_templates", method: "POST", body: ["_operation": .string(operation), "_body": .object(body)], expectedAccount: account)
        try requireReauthentication(context)
        guard data.count <= 3_000_000, let raw = try? TaskfoldJSONDecoder().decode([String: JSON].self, from: data) else { throw TeamTemplateLibraryValue.invalid }; return raw
    }
    func teamTemplatePage(team: String, account: String, origin: String, after: String? = nil, revision: Double? = nil) async throws -> TeamTemplatePage {
        guard TeamProjectValue.id(team), after == nil || TeamProjectValue.id(after!), after == nil || revision != nil else { throw TeamTemplateLibraryValue.invalid }
        var body: [String: JSON] = ["team_id": .string(team)]
        if let after { body["cursor"] = .string(after) }
        if let revision { _ = try TeamTemplateLibraryValue.revision(.number(revision), zero: true); body["library_revision"] = .number(revision) }
        return try .init(await teamTemplateRead("list", body: body, account: account, origin: origin), account: account, origin: origin, team: team, after: after, revision: revision)
    }
    func teamTemplateDetail(team: String, template: String, account: String, origin: String) async throws -> TeamTemplateDetail {
        guard TeamProjectValue.id(team), TeamProjectValue.id(template) else { throw TeamTemplateLibraryValue.invalid }
        return try .init(await teamTemplateRead("get", body: ["team_id": .string(team), "template_id": .string(template)], account: account, origin: origin), account: account, origin: origin, team: team, template: template)
    }
    func teamTemplateCommand(_ command: TeamTemplateCommand) async throws -> TeamTemplateReceipt {
        try command.confirmed(await teamTemplateRead(command.action.rawValue, body: command.body, account: command.account, origin: command.origin))
    }

}

/// A reviewed read becomes a private artifact only after the exact definition and
/// account/session/workspace have been checked again. No shared IDs or authority
/// are copied into the new personal template.
struct TeamTemplateTransferReview: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: UUID
    let detail: TeamTemplateDetail
    let workspace: WorkspaceBinding
    let session: UUID
    var description: String { "Private team template transfer review" }
    var debugDescription: String { description }
    init(detail: TeamTemplateDetail, workspace: WorkspaceBinding, session: UUID, id: UUID = UUID()) throws {
        guard detail.scope.account == workspace.account, detail.supported != nil, id.uuidString.lowercased() != detail.metadata.id else { throw TeamTemplateLibraryValue.invalid }
        self.detail = detail; self.workspace = workspace; self.session = session; self.id = id
    }
    func verify(latest: TeamTemplateDetail, workspace: WorkspaceBinding, session: UUID) throws {
        guard latest == detail, self.workspace == workspace, self.session == session else { throw TeamTemplateLibraryValue.invalid }
    }
    func privateCopy(name: String) throws -> Record {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try TeamTemplateLibraryValue.name(.string(name)); _ = try WorkflowTemplate(document: detail.document)
        return Record(["id": .string(id.uuidString.lowercased()), "user_id": .string(workspace.account), "name": .string(name), "document": detail.document])
    }
    func export(name: String) throws -> WorkflowTemplateFile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try TeamTemplateLibraryValue.name(.string(name))
        return try WorkflowTemplateFile(name: name, document: detail.document)
    }
}
