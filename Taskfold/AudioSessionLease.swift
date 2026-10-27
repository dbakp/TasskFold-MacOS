import Foundation

/// One owner across Taskfold dictation, audio recording and private playback.
@MainActor enum TaskfoldAudioLease {
    private(set) static var owner: UUID?
    static func claim(_ id: UUID) -> Bool { guard owner == nil || owner == id else { return false }; owner = id; return true }
    static func release(_ id: UUID) { if owner == id { owner = nil } }
}
