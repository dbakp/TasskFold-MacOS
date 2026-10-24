import Foundation
import Observation

/// Transient project-only presentation, never a serialized source of authority.
struct TeamTaskRecipientCatalog: Equatable, Sendable {
    struct Person: Equatable, Sendable, Identifiable {
        let id: String
        let role: TeamProjectRole
        let displayName: String?
    }
    let account: String
    let origin: String
    let team: String
    let project: String
    let accessToken: String
    let people: [Person]
    static var invalid: AppFailure { AppFailure(message: "This project’s assignment choices need a fresh review.") }
    init(_ raw: [String: JSON], draft: TeamTaskEditorDraft) throws {
        guard Set(raw.keys) == ["recipient_protocol", "account", "team_id", "project_id", "access_token", "recipients"],
              raw["recipient_protocol"] == .number(1), raw["account"] == .string(draft.scope.account),
              raw["team_id"] == .string(draft.scope.team), raw["project_id"] == .string(draft.scope.project),
              raw["access_token"] == .string(draft.accessToken), case .array(let rows)? = raw["recipients"], rows.count <= 500 else { throw Self.invalid }
        people = try rows.map { value in
            guard case .object(let row) = value, Set(row.keys) == ["user_id", "role", "display_name"],
                  let id = row["user_id"]?.text, TeamProjectValue.id(id),
                  let role = TeamProjectRole(rawValue: row["role"]?.text ?? ""), [.manager, .editor].contains(role),
                  row["display_name"] == .null || TeamOrganizationDetail.Member.identity(row["display_name"]) != nil else { throw Self.invalid }
            return Person(id: id, role: role, displayName: TeamOrganizationDetail.Member.identity(row["display_name"]))
        }
        guard Set(people.map(\.id)).count == people.count, people.map(\.id) == people.map(\.id).sorted(),
              people.contains(where: { $0.id == draft.scope.account }) else { throw Self.invalid }
        account = draft.scope.account; origin = draft.scope.origin; team = draft.scope.team; project = draft.scope.project; accessToken = draft.accessToken
    }
    func belongs(to draft: TeamTaskEditorDraft) -> Bool {
        account == draft.scope.account && origin == draft.scope.origin && team == draft.scope.team && project == draft.scope.project && accessToken == draft.accessToken
    }
}

extension Backend {
    func teamTaskRecipients(_ draft: TeamTaskEditorDraft) async throws -> TeamTaskRecipientCatalog {
        let context = try reauthenticationContext(account: draft.scope.account)
        guard context.origin == draft.scope.origin, context.incarnation == draft.session else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_team_task_recipients", method: "POST", body: ["_team_id": .string(draft.scope.team), "_project_id": .string(draft.scope.project)], expectedAccount: draft.scope.account)
        try requireReauthentication(context)
        guard data.count <= 350_000, let raw = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamTaskRecipientCatalog.invalid }
        return try TeamTaskRecipientCatalog(raw, draft: draft)
    }
}

/// A tap re-reads current recipients. A stale or late reply cannot call the
/// editor, and failures remove names instead of retaining an old directory.
@MainActor @Observable final class TeamTaskRecipientPicker {
    private(set) var catalog: TeamTaskRecipientCatalog?
    private(set) var loading = false
    private(set) var applying = false
    private(set) var message: String?
    private var attempt = UUID()
    private let draft: TeamTaskEditorDraft
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let read: () async throws -> TeamTaskRecipientCatalog
    @ObservationIgnored private let apply: (TeamTaskRecipientCatalog.Person?) -> String?
    init(draft: TeamTaskEditorDraft, current: @escaping () -> Bool, read: @escaping () async throws -> TeamTaskRecipientCatalog, apply: @escaping (TeamTaskRecipientCatalog.Person?) -> String?) {
        self.draft = draft; self.current = current; self.read = read; self.apply = apply
    }
    func invalidate() { attempt = UUID(); catalog = nil; loading = false; applying = false; message = nil }
    func refresh() async {
        invalidate(); guard current() else { return }; let id = attempt; loading = true
        defer { if id == attempt { loading = false } }
        do {
            let value = try await read()
            guard id == attempt else { return }
            guard current(), !Task.isCancelled else { invalidate(); return }
            guard value.belongs(to: draft) else { throw TeamTaskRecipientCatalog.invalid }
            catalog = value
        } catch {
            guard id == attempt else { return }; catalog = nil
            message = current() ? "Couldn’t refresh assignment choices. Try again." : nil
        }
    }
    private func accept(_ person: TeamTaskRecipientCatalog.Person?) -> Bool {
        if let failure = apply(person) { message = failure; return false }
        return true
    }
    func choose(_ user: String?) async -> Bool {
        guard current(), !Task.isCancelled else { invalidate(); return false }
        guard !applying else { return false }
        // These choices need no directory. Their existing captured actor/role
        // becomes an ordinary scoped offline intent, never server authority.
        if user == nil || user == draft.scope.account {
            invalidate()
            return accept(user.map { TeamTaskRecipientCatalog.Person(id: $0, role: draft.role, displayName: nil) })
        }
        guard !loading, let catalog, let known = catalog.people.first(where: { $0.id == user }) else { return false }
        let id = attempt; applying = true; message = nil
        defer { if id == attempt { applying = false } }
        do {
            let fresh = try await read()
            guard id == attempt else { return false }
            guard current(), !Task.isCancelled else { invalidate(); return false }
            guard fresh.belongs(to: draft) else { throw TeamTaskRecipientCatalog.invalid }
            self.catalog = fresh
            guard let person = fresh.people.first(where: { $0.id == user }) else { message = "That person no longer has editing access to this project. Choose someone from the updated list."; return false }
            return accept(person)
        } catch {
            guard id == attempt else { return false }
            guard current(), !Task.isCancelled else { invalidate(); return false }
            // Connectivity loss can retain an already reviewed in-memory choice
            // as a frozen intent. The service rechecks live recipients on sync.
            if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code), catalog.belongs(to: draft) {
                return accept(known)
            }
            self.catalog = nil
            message = "Couldn’t check this assignment. No assignment was applied; refresh the list to try again."
            return false
        }
    }
}
