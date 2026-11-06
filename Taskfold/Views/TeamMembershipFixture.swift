import SwiftUI

#if DEBUG
/// Exact test identity only. Accounts, email addresses and server files are
/// synthetic; this peer never uses Auth, sends mail or accesses real tasks.
enum TeamMembershipFixture {
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowteststeammembers", "com.dbakp.taskfold.mac.workflowteststeammembers"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--team-membership-testing")
    }
    static let team = "ea320000-0000-4000-8000-000000000010"
    static let owner = "ea320000-0000-4000-8000-000000000001"
    static let admin = "ea320000-0000-4000-8000-000000000002"
    static let member = "ea320000-0000-4000-8000-000000000003"
    static let guest = "ea320000-0000-4000-8000-000000000004"
    static let joiner = "ea320000-0000-4000-8000-000000000005"
    static var account: String {
        switch ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--team-actor=") })?.split(separator: "=").last {
        case "admin": return admin
        case "member": return member
        case "guest": return guest
        case "joiner": return joiner
        default: return owner
        }
    }
    static func email(_ account: String) -> String {
        [owner: "owner@example.invalid", admin: "admin@example.invalid", member: "member@example.invalid", guest: "guest@example.invalid", joiner: "joiner@example.invalid"][account] ?? "unknown@example.invalid"
    }
    static let origin = "https://synthetic.example"
    static var setupEnabled: Bool { !ProcessInfo.processInfo.arguments.contains("--team-setup-paused") }
    @MainActor private static let peer = TeamMembershipFixturePeer()
    @MainActor static func browser() -> TeamOrganizationBrowser {
        TeamOrganizationBrowser(account: account, origin: origin, current: { enabled }, overview: { try peer.overview() }, detail: { try peer.detail($0) })
    }
    @MainActor static func commands() -> TeamOrganizationCommandModel {
        TeamOrganizationCommandModel(account: account, origin: origin, vault: TeamOrganizationCommandVault(io: TeamMembershipFixtureIO()), service: peer, isCurrent: { enabled })
    }
}
private struct TeamMembershipFixtureIO: CalendarSecureItemIO {
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TeamMembershipFixture", isDirectory: true) }
    func read(key: String) throws -> Data? { let url = Self.root.appendingPathComponent(key + ".json"); return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
    func write(_ data: Data, key: String) throws { try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true); try data.write(to: Self.root.appendingPathComponent(key + ".json"), options: .atomic) }
    func remove(key: String) throws { let url = Self.root.appendingPathComponent(key + ".json"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
@MainActor private final class TeamMembershipFixturePeer: TeamOrganizationCommandService {
    private var file: URL { TeamMembershipFixtureIO.root.appendingPathComponent("peer.json") }
    private func read() throws -> [String: JSON] {
        if FileManager.default.fileExists(atPath: file.path) { return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: file)) }
        let team = TeamMembershipFixture.team
        let members: [JSON] = [(TeamMembershipFixture.owner, "owner"), (TeamMembershipFixture.admin, "admin"), (TeamMembershipFixture.member, "member"), (TeamMembershipFixture.guest, "guest")].map { .object(["user_id": .string($0.0), "role": .string($0.1)]) }
        return ["teams": .object([team: .object(["id": .string(team), "name": .string("Design studio"), "state": .string("active"), "revision": .number(3)])]),
            "owners": .object([team: .string(TeamMembershipFixture.owner)]), "members": .object([team: .array(members)]),
            "folders": .object([team: .array([.object(["id": .string("ea320000-0000-4000-8000-000000000011"), "name": .string("Design systems"), "position": .number(0)])])]),
            "invitations": .object([:]), "transfers": .object([:]), "requests": .object([:]), "receipts": .object([:]), "history": .array([]), "lost_role_reply": .bool(false)]
    }
    private func write(_ data: [String: JSON]) throws { try FileManager.default.createDirectory(at: TeamMembershipFixtureIO.root, withIntermediateDirectories: true); try TaskfoldJSONEncoder().encode(data).write(to: file, options: .atomic) }
    private func role(_ data: [String: JSON], team: String, account: String) -> String? {
        guard data["teams"]!.object[team]?.object["state"] != .string("deleted"), let row = data["members"]!.object[team]?.list.first(where: { $0.object["user_id"] == .string(account) }) else { return nil }
        return data["owners"]!.object[team] == .string(account) ? "owner" : row.object["role"]?.text
    }
    func overview() throws -> TeamOrganizationOverview {
        let data = try read(), account = TeamMembershipFixture.account
        let teams: [JSON] = data["teams"]!.object.values.compactMap { value in
            var row = value.object; guard let role = role(data, team: row["id"]!.text, account: account) else { return nil }; row["role"] = .string(role); return .object(row)
        }
        let invitations: [JSON] = data["invitations"]!.object.values.compactMap { value in
            let i = value.object, id = i["team_id"]!.text
            guard i["email"] == .string(TeamMembershipFixture.email(account)), let team = data["teams"]!.object[id]?.object, team["state"] == .string("active"), ((try? TeamOrganizationValue.date(i["expires_at"])) ?? .distantPast) > Date() else { return nil }
            return .object(["id": i["id"]!, "team_id": .string(id), "team_name": team["name"]!, "team_revision": team["revision"]!, "role": i["role"]!, "expires_at": i["expires_at"]!])
        }
        return try TeamOrganizationOverview(list: ["enabled": .bool(TeamMembershipFixture.setupEnabled), "teams": .array(teams)], invitations: ["enabled": .bool(TeamMembershipFixture.setupEnabled), "invitations": .array(invitations)], account: account, origin: TeamMembershipFixture.origin)
    }
    func detail(_ id: String) throws -> TeamOrganizationDetail {
        let data = try read(); guard let role = role(data, team: id, account: TeamMembershipFixture.account), var team = data["teams"]!.object[id]?.object else { throw TeamOrganizationCommandFailure(code: "PT404") }
        team["role"] = .string(role)
        if role != "guest" { team["folders"] = data["folders"]!.object[id] ?? .array([]) }
        if ["owner", "admin"].contains(role) {
            team["members"] = .array((data["members"]!.object[id]?.list ?? []).map { value in
                var row = value.object
                let account = row["user_id"]!.text
                let names = [TeamMembershipFixture.owner: "Alex Rivera", TeamMembershipFixture.admin: "Sam Chen", TeamMembershipFixture.member: "Sam Chen"]
                row["display_name"] = names[account].map(JSON.string) ?? .null
                row["verified_email"] = account == TeamMembershipFixture.guest ? .null : .string(TeamMembershipFixture.email(account))
                return .object(row)
            })
            team["invitations"] = .array(data["invitations"]!.object.values.filter { $0.object["team_id"] == .string(id) })
        }
        if let transfer = data["transfers"]!.object[id], role == "owner" || transfer.object["target_id"] == .string(TeamMembershipFixture.account) { team["transfer"] = transfer }
        return try TeamOrganizationDetail(team, team: id, account: TeamMembershipFixture.account, origin: TeamMembershipFixture.origin)
    }
    func teamOrganizationCommand(_ command: TeamOrganizationCommand) async throws -> TeamOrganizationCommandReceipt {
        guard TeamMembershipFixture.enabled, command.account == TeamMembershipFixture.account, command.origin == TeamMembershipFixture.origin else { throw CancellationError() }
        var data = try read(), teams = data["teams"]!.object, owners = data["owners"]!.object, members = data["members"]!.object, folders = data["folders"]!.object
        var invitations = data["invitations"]!.object, transfers = data["transfers"]!.object, requests = data["requests"]!.object, receipts = data["receipts"]!.object
        let action = command.action, teamID = command.team, account = command.account, currentRole = role(data, team: teamID, account: account)
        let request: JSON = .object(["account": .string(account), "action": .string(action.rawValue), "body": .object(command.body)])
        var team = teams[teamID]?.object ?? [:]
        if team["state"] == .string("deleted"), action == .delete, requests[command.id] == request, let old = receipts[command.id] { return try command.confirmed(old.object) }
        guard TeamMembershipFixture.setupEnabled || action.allowedWhilePaused else { throw TeamOrganizationCommandFailure(code: "PT503") }
        if action != .create {
            if currentRole == nil && [.acceptInvitation, .declineInvitation].contains(action) {
                guard let invitation = invitations[command.body["invitation_id"]!.text]?.object, invitation["team_id"] == .string(teamID), invitation["email"] == .string(TeamMembershipFixture.email(account)), try TeamOrganizationValue.date(invitation["expires_at"]) > Date() else { throw TeamOrganizationCommandFailure(code: "PT404") }
            } else if currentRole == nil { throw TeamOrganizationCommandFailure(code: "PT404") }
            if [.archive, .unarchive, .delete, .transferOffer, .transferCancel].contains(action), currentRole != "owner" { throw TeamOrganizationCommandFailure(code: "42501") }
            if [.rename, .folderCreate, .folderRename, .folderRemove, .invite, .revokeInvitation, .changeRole, .removeMember].contains(action), !["owner", "admin"].contains(currentRole ?? "") { throw TeamOrganizationCommandFailure(code: "42501") }
        }
        if let old = requests[command.id] { guard old == request, let reply = receipts[command.id] else { throw TeamOrganizationCommandFailure(code: "PT409") }; return try command.confirmed(reply.object) }
        var roster = members[teamID]?.list ?? [], folderList = folders[teamID]?.list ?? []
        if action == .create {
            guard team.isEmpty else { throw TeamOrganizationCommandFailure(code: "PT409") }
            team = ["id": .string(teamID), "name": command.body["name"]!, "state": .string("active"), "revision": .number(1)]
            owners[teamID] = .string(account); roster = [.object(["user_id": .string(account), "role": .string("owner")])]
        } else {
            guard team["revision"] == command.body["revision"], team["state"] != .string("deleted"), team["state"] != .string("archived") || action.allowedWhileArchived else { throw TeamOrganizationCommandFailure(code: "PT409") }
            team["revision"] = .number(Double(team["revision"]!.integer + 1))
        }
        var result: [String: JSON] = ["id": .string(teamID), "revision": team["revision"]!, "state": .string(command.resultState)]
        switch action {
        case .create: break
        case .rename: team["name"] = command.body["name"]
        case .archive: team["state"] = .string("archived")
        case .unarchive: team["state"] = .string("active")
        case .delete:
            team["state"] = .string("deleted"); team["name"] = .null; owners.removeValue(forKey: teamID); roster = []; folderList = []
            invitations = invitations.filter { $0.value.object["team_id"] != .string(teamID) }; transfers.removeValue(forKey: teamID)
        case .invite:
            let email = command.email!, role = command.body["role"]!.text
            guard role != "admin" || currentRole == "owner", email != TeamMembershipFixture.email(account), !invitations.values.contains(where: { $0.object["team_id"] == .string(teamID) && $0.object["email"] == .string(email) }) else { throw TeamOrganizationCommandFailure(code: "PT409") }
            let id = UUID().uuidString.lowercased(), formatter = ISO8601DateFormatter()
            invitations[id] = .object(["id": .string(id), "team_id": .string(teamID), "email": .string(email), "role": .string(role), "invited_by": .string(account), "expires_at": .string(formatter.string(from: Date().addingTimeInterval(604800)))])
            result["invitation_id"] = .string(id)
        case .acceptInvitation, .declineInvitation, .revokeInvitation:
            let id = command.body["invitation_id"]!.text
            guard let invitation = invitations[id]?.object, invitation["team_id"] == .string(teamID) else { throw TeamOrganizationCommandFailure(code: "PT404") }
            if action == .revokeInvitation { guard currentRole == "owner" || invitation["role"] != .string("admin") else { throw TeamOrganizationCommandFailure(code: "42501") } }
            else { guard invitation["email"] == .string(TeamMembershipFixture.email(account)), try TeamOrganizationValue.date(invitation["expires_at"]) > Date() else { throw TeamOrganizationCommandFailure(code: "PT404") } }
            if action == .acceptInvitation {
                guard currentRole == nil else { throw TeamOrganizationCommandFailure(code: "PT409") }
                roster.append(.object(["user_id": .string(account), "role": invitation["role"]!]))
            }
            invitations.removeValue(forKey: id)
        case .changeRole, .removeMember, .leave:
            let target = action == .leave ? account : command.body["user_id"]!.text
            guard owners[teamID] != .string(target), let index = roster.firstIndex(where: { $0.object["user_id"] == .string(target) }) else { throw TeamOrganizationCommandFailure(code: "PT409") }
            let oldRole = roster[index].object["role"]!.text
            guard action == .leave || currentRole == "owner" || oldRole != "admin" else { throw TeamOrganizationCommandFailure(code: "42501") }
            if action == .changeRole {
                guard command.body["role"] != .string("admin") || currentRole == "owner" else { throw TeamOrganizationCommandFailure(code: "42501") }
                var row = roster[index].object; row["role"] = command.body["role"]; roster[index] = .object(row)
            } else { roster.remove(at: index) }
            invitations = invitations.filter { !($0.value.object["team_id"] == .string(teamID) && $0.value.object["invited_by"] == .string(target)) }
            if transfers[teamID]?.object["target_id"] == .string(target) || transfers[teamID]?.object["proposed_by"] == .string(target) { transfers.removeValue(forKey: teamID) }
        case .transferOffer:
            let target = command.body["user_id"]!.text
            guard target != account, let row = roster.first(where: { $0.object["user_id"] == .string(target) }), ["admin", "member"].contains(row.object["role"]!.text) else { throw TeamOrganizationCommandFailure(code: "22023") }
            let id = UUID().uuidString.lowercased(), formatter = ISO8601DateFormatter()
            transfers[teamID] = .object(["id": .string(id), "target_id": .string(target), "proposed_by": .string(account), "expires_at": .string(formatter.string(from: Date().addingTimeInterval(86400)))])
            result["transfer_id"] = .string(id)
        case .transferAccept:
            guard let offer = transfers[teamID]?.object, offer["id"] == command.body["transfer_id"], offer["target_id"] == .string(account), offer["proposed_by"] == owners[teamID], ["admin", "member"].contains(currentRole ?? ""), try TeamOrganizationValue.date(offer["expires_at"]) > Date() else { throw TeamOrganizationCommandFailure(code: "PT404") }
            let oldOwner = owners[teamID]; owners[teamID] = .string(account)
            roster = roster.map { value in var row = value.object; if row["user_id"] == oldOwner { row["role"] = .string("admin") }; if row["user_id"] == .string(account) { row["role"] = .string("owner") }; return .object(row) }
            invitations = invitations.filter { $0.value.object["team_id"] != .string(teamID) }; transfers.removeValue(forKey: teamID)
        case .transferCancel: transfers.removeValue(forKey: teamID)
        case .folderCreate:
            let id = UUID().uuidString.lowercased(); folderList.append(.object(["id": .string(id), "name": command.body["name"]!, "position": .number(Double((folderList.map { $0.object["position"]!.integer }.max() ?? -1) + 1))])); result["folder_id"] = .string(id)
        case .folderRename, .folderRemove:
            guard let i = folderList.firstIndex(where: { $0.object["id"] == command.body["folder_id"] }) else { throw TeamOrganizationCommandFailure(code: "PT404") }
            if action == .folderRemove { folderList.remove(at: i) } else { var row = folderList[i].object; row["name"] = command.body["name"]; folderList[i] = .object(row) }
        }
        let confirmed = try command.confirmed(result)
        teams[teamID] = .object(team); members[teamID] = .array(roster); folders[teamID] = .array(folderList)
        requests[command.id] = request; receipts[command.id] = .object(result)
        data["teams"] = .object(teams); data["owners"] = .object(owners); data["members"] = .object(members); data["folders"] = .object(folders); data["invitations"] = .object(invitations); data["transfers"] = .object(transfers); data["requests"] = .object(requests); data["receipts"] = .object(receipts)
        var history = data["history"]!.list; history.append(.object(["request_id": .string(command.id), "request": request, "result": .object(result)])); data["history"] = .array(history)
        if action == .changeRole, data["lost_role_reply"] == .bool(false), ProcessInfo.processInfo.arguments.contains("--team-membership-lose-role-reply") { data["lost_role_reply"] = .bool(true); try write(data); throw URLError(.networkConnectionLost) }
        try write(data); return confirmed
    }
}
#endif
