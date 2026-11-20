import Foundation

/// An in-memory capture request survives replacement of the destination view.
/// It belongs to one workspace incarnation and is consumed once by its surface.
struct CapturePresentationQueue {
    struct Request: Equatable, Sendable {
        let id = UUID()
        let destination: String
        let workspace: WorkspaceBinding
    }
    private(set) var pending: Request?

    mutating func request(destination: String, workspace: WorkspaceBinding) {
        guard !workspace.account.isEmpty else { pending = nil; return }
        pending = Request(destination: destination, workspace: workspace)
    }
    mutating func take(destination: String, account: String, generation: UUID) -> Bool {
        guard let request = pending else { return false }
        guard request.workspace.matches(account: account, generation: generation) else {
            pending = nil; return false
        }
        guard request.destination == destination else { return false }
        pending = nil
        return true
    }
    mutating func cancel() { pending = nil }
}

/// The "Draft restored · Clear" notice in Quick Add. A composer reopened with text means an earlier session closed with an
/// unsent draft (an empty or sent composer is cleared on close), so the notice shows only for non-blank opening text.
enum QuickAddDraftNotice {
    static func isRestored(openingText: String) -> Bool { !openingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
