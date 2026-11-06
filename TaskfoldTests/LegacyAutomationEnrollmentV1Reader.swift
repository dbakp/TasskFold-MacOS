import Foundation
@testable import TaskfoldCore

// Exact prior private-envelope reader, type renamed for compilation beside the new reader.
// Source SHA256: 8ff3ffc515bfca881f49c9e7349ccebb5bda5974d21084b6ba6debbcf1f9f933
struct LegacyAutomationEnrollmentV1Reader: Codable {
    let version: Int
    let id: String
    let account: String
    let origin: String
    let name: String
    let scopes: [AutomationScope]
    let days: Int
    let secret: String
    init(_ draft: AutomationKeyDraft) {
        version = 1; id = draft.id; account = draft.account; origin = draft.origin
        name = draft.name; scopes = draft.scopes; days = draft.days; secret = draft.secretForOneTimeReview
    }
    func draft() throws -> AutomationKeyDraft {
        guard version == 1, AutomationKey.canonicalID(id), Set(scopes).count == scopes.count,
              secret.utf8.count == 83, secret.hasPrefix("tfk_v1_" + id.replacingOccurrences(of: "-", with: "") + "_") else { throw AutomationKey.invalid }
        let encoded = String(secret.suffix(43)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: encoded) else { throw AutomationKey.invalid }
        let value = try AutomationKeyDraft(account: account, origin: origin, name: name, scopes: Set(scopes), days: days,
                                           id: UUID(uuidString: id)!, entropy: { bytes })
        guard value.secretForOneTimeReview == secret, value.origin == origin, value.name == name else { throw AutomationKey.invalid }
        return value
    }
}

