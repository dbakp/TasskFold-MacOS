import Foundation

/// The shared `Store` updates a "Next up" Live Activity after every persist. ActivityKit can be imported on
/// macOS, so the Core call compiles, but Live Activities are an iOS surface; this keeps the shared file
/// unchanged and makes the hook a no-op on the Mac.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    func update(tasks: [Record], projects: [Record]) {}
    func endAll() {}
}
