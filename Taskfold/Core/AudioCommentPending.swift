import Foundation

/// One atomic journal payload holds both the frozen intent and its exact audio.
/// The owning account store must persist this before making a network request.
/// This value does not establish permission to publish or play after relaunch.
struct AudioCommentPending: Sendable {
    private static let maximumEncodedBytes = AudioCommentDescriptor.maximumBytes + 100_000
    let publication: AudioCommentPublication
    let clip: AudioCommentClip
    init(publication: AudioCommentPublication, clip: AudioCommentClip) throws {
        guard clip.verifies(publication.descriptor) else { throw AudioCommentFailure.invalid }
        self.publication = publication; self.clip = clip
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "format": "taskfold-audio-pending-v1",
            "intent": try encoder.encode(publication),
            "audio": clip.data
        ], format: .binary, options: 0)
        guard data.count <= Self.maximumEncodedBytes else { throw AudioCommentFailure.invalid }
        return data
    }
    init(encoded data: Data, account: UUID) throws {
        guard !data.isEmpty, data.count <= Self.maximumEncodedBytes else { throw AudioCommentFailure.invalid }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let fields = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              format == .binary, Set(fields.keys) == ["format", "intent", "audio"],
              fields["format"] as? String == "taskfold-audio-pending-v1",
              let intent = fields["intent"] as? Data, intent.count <= 32_000,
              let audio = fields["audio"] as? Data else { throw AudioCommentFailure.invalid }
        let publication = try JSONDecoder().decode(AudioCommentPublication.self, from: intent)
        guard publication.account == account else { throw AudioCommentFailure.changed }
        try self.init(publication: publication, clip: AudioCommentClip(restoring: audio, descriptor: publication.descriptor))
    }
}
