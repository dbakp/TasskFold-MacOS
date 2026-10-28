import Foundation
import CryptoKit
@testable import TaskfoldCore

@main struct AudioPortableFileProof {
    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1]), expected = Data(CommandLine.arguments[2].utf8)
        let handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: AudioCommentPortableRecording.maximumFileBytes + 1) ?? Data()
        let portable = try AudioCommentPortableRecording(encoded: bytes)
        guard Data(portable.caption.utf8) == expected else { throw AudioCommentFailure.invalid }
        let decoded = try await AudioCommentDecoding.validate(portable.clip.data)
        guard decoded.data == portable.clip.data else { throw AudioCommentFailure.invalid }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let result: [String: Any] = ["format": AudioCommentPortableRecording.format, "fileSHA256": digest(bytes),
                                   "fileBytes": bytes.count, "audioSHA256": digest(decoded.data), "audioBytes": decoded.data.count,
                                   "captionSHA256": digest(expected), "captionBytes": expected.count,
                                   "storedMilliseconds": portable.clip.descriptor.milliseconds, "decodedMilliseconds": decoded.descriptor.milliseconds,
                                   "fullNativeDecode": true, "exactCaption": true, "exactAudio": true]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    }
}
