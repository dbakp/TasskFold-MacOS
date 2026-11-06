import XCTest
@testable import TaskfoldCore

final class TeamOrganizationMembershipTests: XCTestCase {
    private let origin = "https://backend.example"
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-organization-overview-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func detail(_ role: String = "owner", archived: Bool = false, invitationRole: String? = nil, transfer: Bool = false) throws -> TeamOrganizationDetail {
        let raw = try fixture(), actor = raw[role]!.object
        var row = actor["detail"]!.object
        if archived { row["state"] = .string("archived") }
        if let invitationRole {
            row["invitations"] = .array([.object(["id": .string("ea330000-0000-4000-8000-000000000001"), "email": .string("joiner@example.invalid"), "role": .string(invitationRole), "expires_at": .string("2030-10-24T10:00:00Z")])])
        }
        if transfer {
            let member = raw["member"]!.object["account"]!
            row["transfer"] = .object(["id": .string("ea330000-0000-4000-8000-000000000002"), "target_id": member, "expires_at": .string("2030-10-24T10:00:00Z")])
        }
        return try TeamOrganizationDetail(row, team: raw["team"]!.text, account: actor["account"]!.text, origin: origin)
    }
    func testOwnersAndAdminsHaveDifferentRoleAndInvitationChoices() throws {
        let owner = TeamOrganizationAdministration(detail: try detail(invitationRole: "admin"), enabled: true)
        let admin = TeamOrganizationAdministration(detail: try detail("admin", invitationRole: "admin"), enabled: true)
        XCTAssertEqual(owner.assignableRoles, [.admin, .member, .guest]); XCTAssertEqual(admin.assignableRoles, [.member, .guest])
        for member in owner.detail.members {
            let selfOrOwner = member.id == owner.detail.account || member.role == .owner
            XCTAssertEqual(owner.allows(.changeRole, member: member), !selfOrOwner)
            XCTAssertEqual(owner.allows(.removeMember, member: member), !selfOrOwner)
            let adminTarget = admin.detail.members.first { $0.id == member.id }!
            XCTAssertEqual(admin.allows(.changeRole, member: adminTarget), member.role != .admin && member.role != .owner)
        }
        XCTAssertTrue(owner.allows(.revokeInvitation, invitation: owner.detail.invitations[0]))
        XCTAssertFalse(admin.allows(.revokeInvitation, invitation: admin.detail.invitations[0]))
    }
    func testMemberAndGuestHaveNoAdministrationButCanLeave() throws {
        let owner = try detail()
        for role in ["member", "guest"] {
            let value = TeamOrganizationAdministration(detail: try detail(role), enabled: true)
            for action in [TeamOrganizationCommand.Action.invite, .rename, .archive, .unarchive, .delete, .folderCreate] { XCTAssertFalse(value.allows(action)) }
            for member in owner.members { XCTAssertFalse(value.allows(.removeMember, member: member)); XCTAssertFalse(value.allows(.transferOffer, member: member)) }
            XCTAssertTrue(value.allows(.leave))
        }
    }
    func testPausedAndArchivedTeamsKeepOnlyRecoveryActions() throws {
        for archived in [false, true] {
            let policy = TeamOrganizationAdministration(detail: try detail(archived: archived, invitationRole: "member", transfer: true), enabled: false)
            for action in [TeamOrganizationCommand.Action.rename, .archive, .unarchive, .folderCreate, .invite, .changeRole] { XCTAssertFalse(policy.allows(action)) }
            XCTAssertTrue(policy.allows(.delete)); XCTAssertTrue(policy.allows(.transferCancel))
            let target = try XCTUnwrap(policy.detail.members.first { $0.role == .member })
            XCTAssertTrue(policy.allows(.removeMember, member: target)); XCTAssertTrue(policy.allows(.transferOffer, member: target))
            XCTAssertTrue(policy.allows(.revokeInvitation, invitation: policy.detail.invitations[0]))
        }
    }
    func testOwnershipRequiresAnAcceptedNonGuestAndExplicitRecipient() throws {
        let policy = TeamOrganizationAdministration(detail: try detail(transfer: true), enabled: true)
        for member in policy.detail.members {
            XCTAssertEqual(policy.allows(.transferOffer, member: member), [.admin, .member].contains(member.role))
        }
        XCTAssertFalse(policy.allows(.transferAccept)); XCTAssertFalse(policy.allows(.leave))
        let recipient = TeamOrganizationAdministration(detail: try detail("member", transfer: true), enabled: false)
        XCTAssertTrue(recipient.allows(.transferAccept))
        XCTAssertFalse(recipient.allows(.transferAccept, now: Date(timeIntervalSince1970: 2_000_000_000)))
    }
    func testInvitationExpiryAndUnknownTargetsCannotBeManaged() throws {
        let policy = TeamOrganizationAdministration(detail: try detail(invitationRole: "guest"), enabled: true)
        XCTAssertFalse(policy.allows(.revokeInvitation, invitation: policy.detail.invitations[0], now: Date(timeIntervalSince1970: 2_000_000_000)))
        let foreign = TeamOrganizationDetail.Member(id: "ea330000-0000-4000-8000-000000000099", role: .member)
        XCTAssertFalse(policy.allows(.changeRole, member: foreign)); XCTAssertFalse(policy.allows(.removeMember, member: foreign)); XCTAssertFalse(policy.allows(.transferOffer, member: foreign))
    }
    func testNewCommandsValidateRolesRecipientsAndExactTargetFields() throws {
        let d = try detail(), member = try XCTUnwrap(d.members.first { $0.role == .member })
        let invite = try TeamOrganizationCommand(account: d.account, origin: origin, action: .invite, team: d.team.id, revision: d.team.revision, email: " Joiner@Example.invalid ", role: .member)
        XCTAssertEqual(invite.email, "joiner@example.invalid")
        XCTAssertFalse(String(reflecting: invite).contains("joiner"))
        for role in [TeamOrganizationRole.owner] {
            XCTAssertThrowsError(try TeamOrganizationCommand(account: d.account, origin: origin, action: .invite, team: d.team.id, revision: 1, email: "joiner@example.invalid", role: role))
            XCTAssertThrowsError(try TeamOrganizationCommand(account: d.account, origin: origin, action: .changeRole, team: d.team.id, revision: 1, role: role, user: member.id))
        }
        for email in ["not-an-address", "a@@b", "a@", "@b", "a b@example.invalid", "a\nb@example.invalid"] {
            XCTAssertThrowsError(try TeamOrganizationCommand(account: d.account, origin: origin, action: .invite, team: d.team.id, revision: 1, email: email, role: .member))
        }
        XCTAssertThrowsError(try TeamOrganizationCommand(account: d.account, origin: origin, action: .acceptInvitation, team: d.team.id, revision: 1))
        XCTAssertThrowsError(try TeamOrganizationCommand(account: d.account, origin: origin, action: .transferAccept, team: d.team.id, revision: 1, user: member.id))
    }
    func testExistingMembershipCannotBeJoinedAgainThroughAnInvitation() throws {
        let raw = try fixture(), owner = raw["owner"]!.object
        let offer: JSON = .object(["id": .string("ea330000-0000-4000-8000-000000000001"), "team_id": raw["team"]!, "team_name": .string("Studio"), "role": .string("member"), "expires_at": .string("2030-10-24T10:00:00Z"), "team_revision": .number(1)])
        let offers: [String: JSON] = ["enabled": .bool(true), "invitations": .array([offer])]
        let existing = try TeamOrganizationOverview(list: owner["list"]!.object, invitations: offers, account: owner["account"]!.text, origin: origin)
        XCTAssertFalse(existing.canAccept(existing.invitations[0]))
        let available = try TeamOrganizationOverview(list: ["enabled": .bool(true), "teams": .array([])], invitations: offers, account: owner["account"]!.text, origin: origin)
        XCTAssertTrue(available.canAccept(available.invitations[0]))
        XCTAssertFalse(available.canAccept(available.invitations[0], now: Date(timeIntervalSince1970: 2_000_000_000)))
    }
    func testArchivedReviewStateIsPrivateAndSurvivesRecovery() throws {
        let d = try detail()
        for action in [TeamOrganizationCommand.Action.leave, .delete, .transferCancel] {
            let command = try TeamOrganizationCommand(account: d.account, origin: origin, action: action, team: d.team.id, revision: 4, state: "archived")
            XCTAssertNil(command.body["reviewedState"]); XCTAssertNil(command.body["state"])
            let roundTrip = try JSONDecoder().decode(TeamOrganizationCommand.self, from: JSONEncoder().encode(command)); XCTAssertEqual(roundTrip, command)
            let state = action == .delete ? "deleted" : "archived"
            XCTAssertNoThrow(try command.confirmed(["id": .string(d.team.id), "revision": .number(5), "state": .string(state)]))
            XCTAssertThrowsError(try command.confirmed(["id": .string(d.team.id), "revision": .number(5), "state": .string("active")]))
        }
        XCTAssertThrowsError(try TeamOrganizationCommand(account: d.account, origin: origin, action: .invite, team: d.team.id, revision: 4, email: "joiner@example.invalid", role: .member, state: "archived"))
    }
    func testLegacyPendingCommandKeepsTheExactBodyWithoutNewReviewMetadata() throws {
        let d = try detail()
        for action in [TeamOrganizationCommand.Action.rename, .unarchive] {
            let command = try TeamOrganizationCommand(account: d.account, origin: origin, action: action, team: d.team.id, revision: 3, name: action == .rename ? "Studio" : nil)
            var raw = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(command)); raw.removeValue(forKey: "reviewedState")
            let recovered = try JSONDecoder().decode(TeamOrganizationCommand.self, from: JSONEncoder().encode(raw))
            XCTAssertEqual(recovered, command); XCTAssertEqual(recovered.id, command.id)
        }
    }
    func testInviteAndTransferReceiptsMustProvideNewIdentifiers() throws {
        let d = try detail(), member = try XCTUnwrap(d.members.first { $0.role == .member })
        let invite = try TeamOrganizationCommand(account: d.account, origin: origin, action: .invite, team: d.team.id, revision: 3, email: "joiner@example.invalid", role: .guest)
        let transfer = try TeamOrganizationCommand(account: d.account, origin: origin, action: .transferOffer, team: d.team.id, revision: 3, user: member.id)
        let base: [String: JSON] = ["id": .string(d.team.id), "revision": .number(4), "state": .string("active")]
        XCTAssertThrowsError(try invite.confirmed(base)); XCTAssertThrowsError(try transfer.confirmed(base))
        XCTAssertNotNil(try invite.confirmed(base.merging(["invitation_id": .string(member.id)]) { _, b in b }).invitation)
        XCTAssertNotNil(try transfer.confirmed(base.merging(["transfer_id": .string(member.id)]) { _, b in b }).transfer)
    }
}
