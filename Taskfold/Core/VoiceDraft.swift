import Foundation

/// The recording is a temporary proposal. Applying text and saving tasks are separate actions.
struct VoiceDraftRequest: Identifiable {
    let id = UUID()
    let workspace: WorkspaceBinding
    let original: String
    /// Swift String equality normalizes Unicode. A proposal must stay bound to
    /// the exact authored source, including canonically equivalent edits.
    func matchesOriginal(_ text: String) -> Bool { original.utf8.elementsEqual(text.utf8) }
}

struct VoiceDraftSession {
    enum Phase { case ready, authorizing, recording, finishing, review, closed }
    static let maximumBytes = 100_000
    let request: VoiceDraftRequest
    var workspace: WorkspaceBinding { request.workspace }
    init(request: VoiceDraftRequest) { self.request = request }
    private(set) var phase: Phase = .ready
    private(set) var text = ""
    private(set) var token: UUID?
    private var base = ""
    var busy: Bool { phase == .authorizing || phase == .recording || phase == .finishing }
    mutating func begin(account: String, generation: UUID) -> UUID? {
        guard phase != .closed, !busy, workspace.matches(account: account, generation: generation) else { return nil }
        let next = UUID(); token = next; base = text; phase = .authorizing; return next
    }
    func accepts(_ token: UUID, account: String, generation: UUID) -> Bool {
        self.token == token && busy && workspace.matches(account: account, generation: generation)
    }
    mutating func started(_ token: UUID, account: String, generation: UUID) {
        guard accepts(token, account: account, generation: generation), phase == .authorizing else { return }
        phase = .recording
    }
    @discardableResult mutating func receive(_ segment: String, token: UUID, account: String, generation: UUID) throws -> Bool {
        guard accepts(token, account: account, generation: generation), phase != .authorizing else { return false }
        // Partial results replace the current segment; they never duplicate earlier words.
        text = try Self.appending(segment, to: base, allowEmpty: true)
        return true
    }
    mutating func finishing() { if phase == .recording { phase = .finishing } }
    mutating func stop() { guard phase != .closed else { return }; token = nil; phase = .review; base = text }
    mutating func close() { token = nil; phase = .closed }
    mutating func edit(_ value: String) throws {
        guard !busy, phase != .closed else { return }
        try Self.validate(value); text = value; base = value
    }
    static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumBytes, !text.contains("\0") else { throw AppFailure(message: "Keep the draft below 100 KB and remove unsupported control characters. Nothing has been applied.") }
    }
    static func appending(_ transcript: String, to original: String, allowEmpty: Bool = false) throws -> String {
        try validate(original); try validate(transcript)
        let addition = transcript.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else {
            if allowEmpty { return original }
            throw AppFailure(message: "Add or dictate some text before applying it.")
        }
        let result = original + (original.isEmpty || original.hasSuffix("\n") || original.hasSuffix("\r") ? "" : "\n") + addition
        try validate(result); return result
    }
    func applying(to original: String, request: VoiceDraftRequest, account: String, generation: UUID) throws -> String {
        guard !busy, phase != .closed, request.id == self.request.id, self.request.matchesOriginal(request.original), request.workspace == workspace,
              workspace.matches(account: account, generation: generation), self.request.matchesOriginal(original) else {
            throw AppFailure(message: "The workspace or original draft changed. Reopen dictation from the intended draft.")
        }
        return try Self.appending(text, to: original)
    }
}
