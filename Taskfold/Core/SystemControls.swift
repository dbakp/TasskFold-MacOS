import Foundation

/// Control Center and Lock Screen controls run in the widget extension, which never holds
/// credentials or the workspace. A tap on the Focus timer control leaves a small, expiring,
/// credential-free request in the App Group; the app applies it through the normal Focus
/// session path and publishes the new state back through the widget snapshot.
struct FocusControlRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case start, stop }
    static let lifetime: TimeInterval = 120
    var id: UUID
    var action: Action
    /// The session the control displayed. A stop never ends a different, newer session.
    var sessionID: String?
    var issuedAt: Date
    init(id: UUID = UUID(), action: Action, sessionID: String?, issuedAt: Date = Date()) {
        self.id = id; self.action = action; self.sessionID = sessionID; self.issuedAt = issuedAt
    }
    func isFresh(at now: Date) -> Bool { now >= issuedAt.addingTimeInterval(-60) && now <= issuedAt.addingTimeInterval(Self.lifetime) }
}

enum SystemControlRoute {
    static let today = URL(string: "taskfold://today")!
}

/// One request slot in the App Group container. A newer tap replaces an older one.
struct FocusControlDisk: @unchecked Sendable {
    static let group = "group.com.dbakp.taskfold"
    private let file: URL
    init(directory: URL) { file = directory.appendingPathComponent("focus-control.json") }
    static func system() -> FocusControlDisk? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group).map { FocusControlDisk(directory: $0) }
    }
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    func write(_ request: FocusControlRequest) throws {
        try Self.encoder.encode(request).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func read() -> FocusControlRequest? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(FocusControlRequest.self, from: data)
    }
    func clear() { try? FileManager.default.removeItem(at: file) }
}
