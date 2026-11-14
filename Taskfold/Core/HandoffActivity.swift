import Foundation
import Observation

/// The one Handoff payload Taskfold advertises and accepts on iPhone, iPad and Mac.
///
/// It carries a destination and ids only: never a task title, note, project name or any other content. The
/// receiving device looks the ids up in its own, already authorised workspace, so a stale, forged or foreign
/// payload can only ever land on something the person could open anyway, or on a plain "not available" message.
/// `parse` is strict because the userInfo of an `NSUserActivity` is untrusted input: unknown keys, wrong types,
/// oversized values and ids that are not plain identifiers are all rejected.
struct HandoffActivity: Equatable, Sendable {
    /// Declared under `NSUserActivityTypes` in each app's Info.plist.
    static let activityType = "com.dbakp.taskfold.continue"
    static let version = 1
    static let maximumIDLength = 64
    static let maximumAccountLength = 200

    enum Destination: Equatable, Sendable {
        case task(String), project(String), today, calendar

        var kind: String {
            switch self { case .task: "task"; case .project: "project"; case .today: "today"; case .calendar: "calendar" }
        }
        var id: String? {
            switch self { case .task(let id), .project(let id): id; case .today, .calendar: nil }
        }
    }

    enum Rejection: String, Error, Equatable, Sendable {
        case malformed, unsupportedVersion, unknownDestination, missingID, invalidID, unexpectedID, missingAccount, invalidAccount, unexpectedField
    }

    /// Why a well-formed payload cannot be continued here. `message` is safe to show.
    enum Failure: Error, Equatable, Sendable {
        case invalid, signedOut, otherWorkspace, unavailable
        var message: String {
            switch self {
            case .invalid: "This Handoff could not be read. Open the item from your list instead."
            case .signedOut: "Sign in to Taskfold to continue what you were viewing on your other device."
            case .otherWorkspace: "That Handoff came from a different workspace. Open the item from your current workspace."
            case .unavailable: "That item is not available in this workspace. It may have been deleted or moved, or you may no longer have access."
            }
        }
    }

    var destination: Destination
    /// The signed-in account id the activity was advertised from. Used only to refuse a different account.
    var account: String

    private enum Key { static let version = "v", kind = "k", id = "id", account = "a" }

    var userInfo: [String: Any] {
        var info: [String: Any] = [Key.version: Self.version, Key.kind: destination.kind, Key.account: account]
        if let id = destination.id { info[Key.id] = id }
        return info
    }

    /// Fills a SwiftUI `.userActivity` or a hand-made `NSUserActivity`. Nothing is made searchable or predictable.
    func apply(to activity: NSUserActivity) {
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        let info = userInfo
        activity.userInfo = info
        activity.requiredUserInfoKeys = Set(info.keys)
    }

    /// Builds an activity for a destination, or nil when the ids or account would not survive `parse`.
    static func make(_ destination: Destination, account: String) -> HandoffActivity? {
        let value = HandoffActivity(destination: destination, account: account)
        if case .failure = parse(value.userInfo) { return nil }
        return value
    }

    static func parse(_ userInfo: [AnyHashable: Any]?) -> Result<HandoffActivity, Rejection> {
        guard let userInfo, !userInfo.isEmpty else { return .failure(.malformed) }
        var fields: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let name = key as? String else { return .failure(.malformed) }
            fields[name] = value
        }
        guard Set(fields.keys).isSubset(of: [Key.version, Key.kind, Key.id, Key.account]) else { return .failure(.unexpectedField) }
        guard let number = fields[Key.version] as? Int else { return .failure(.malformed) }
        guard number == version else { return .failure(.unsupportedVersion) }
        guard let kind = fields[Key.kind] as? String else { return .failure(.malformed) }
        guard let account = fields[Key.account] as? String, !account.isEmpty else { return .failure(.missingAccount) }
        guard validAccount(account) else { return .failure(.invalidAccount) }
        let id = fields[Key.id]
        if id != nil, !(id is String) { return .failure(.invalidID) }
        let text = id as? String
        switch kind {
        case "task", "project":
            guard let text, !text.isEmpty else { return .failure(.missingID) }
            guard validID(text) else { return .failure(.invalidID) }
            return .success(.init(destination: kind == "task" ? .task(text) : .project(text), account: account))
        case "today", "calendar":
            guard text == nil else { return .failure(.unexpectedID) }
            return .success(.init(destination: kind == "today" ? .today : .calendar, account: account))
        default:
            return .failure(.unknownDestination)
        }
    }

    /// Decides whether a received activity may be continued here. The closures look in the receiving device's own
    /// workspace, so a payload never grants access by itself.
    static func resolve(_ userInfo: [AnyHashable: Any]?, account current: String, signedIn: Bool,
                        hasTask: (String) -> Bool, hasProject: (String) -> Bool) -> Result<Destination, Failure> {
        guard case .success(let activity) = parse(userInfo) else { return .failure(.invalid) }
        guard signedIn, !current.isEmpty else { return .failure(.signedOut) }
        guard activity.account == current else { return .failure(.otherWorkspace) }
        switch activity.destination {
        case .task(let id): return hasTask(id) ? .success(activity.destination) : .failure(.unavailable)
        case .project(let id): return hasProject(id) ? .success(activity.destination) : .failure(.unavailable)
        case .today, .calendar: return .success(activity.destination)
        }
    }

    /// Ids are UUIDs or the app's short ids: letters, digits, hyphen and underscore only.
    static func validID(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximumIDLength else { return false }
        return text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }
    private static func validAccount(_ text: String) -> Bool {
        text.utf8.count <= maximumAccountLength && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Lets several screens say what is on screen while one place advertises the single Handoff activity. The most
/// recent claim wins, so a task editor opened over Today advertises the task, and Today again once it closes.
@MainActor @Observable final class HandoffAdvertiser {
    private(set) var claims: [(token: UUID, destination: HandoffActivity.Destination)] = []
    var current: HandoffActivity.Destination? { claims.last?.destination }

    func claim(_ token: UUID, _ destination: HandoffActivity.Destination) {
        if let index = claims.firstIndex(where: { $0.token == token }) {
            guard claims[index].destination != destination else { return }
            claims.remove(at: index)
        }
        claims.append((token, destination))
    }
    func release(_ token: UUID) { claims.removeAll { $0.token == token } }
    func reset() { claims.removeAll() }
}
