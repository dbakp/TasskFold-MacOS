#if DEBUG
import Foundation
import CryptoKit

// The retired JSON child-record native fixtures were removed with their UI. `Core/Store.swift` still names these
// symbols in DEBUG-only code, so these inert stand-ins keep it compiling: nothing here can be switched on.
// Delete this file together with the legacy child-record code in Core.

enum ChildFieldNativeIdentity {
    static let account = "ec990000-0000-4000-8000-000000000001"
    static let other = "ec990000-0000-4000-8000-000000000009"
    static let rootID = "ec990000-0000-4000-8000-000000000002"
    static let origin = "https://synthetic.example"
    static var enabled: Bool { false }
    static func key(_ account: String) throws -> SymmetricKey { throw CancellationError() }
}

struct ChildFieldNativeRefusal: Error { let code: String }

@MainActor enum ChildMappingSQLNativePeer {
    static var enabled: Bool { false }
    static var archivesTesting: Bool { false }
}

@MainActor enum ChildFieldNativePeer {
    static var folder: URL { URL.applicationSupportDirectory.appendingPathComponent("Child field native peer", isDirectory: true) }
    static var root: Record { get throws { throw CancellationError() } }
    static func initial() -> [String: JSON] { [:] }
    static func save(_ state: [String: JSON]) throws { throw CancellationError() }
    static func state() throws -> [String: JSON] { throw CancellationError() }
    static func response(_ request: URLRequest) async throws -> (Data, Bool) { throw CancellationError() }
}

@MainActor enum ChildAdoptionNativePeer {
    static var enabled: Bool { false }
    static func prepareExport(reset: Bool) throws {}
}

@MainActor enum ChildTransferNativePeer {
    static var enabled: Bool { false }
    static func destination(_ state: inout [String: JSON]) -> Record { Record() }
}
#endif
