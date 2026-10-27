import Foundation
import AVFoundation

/// Performs complete bounded AAC decoding without playing or recording audio.
/// Temporary files are private, uniquely owned and removed on every exit path.
enum AudioCommentDecoding {
    static func validate(_ data: Data) async throws -> AudioCommentClip {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { () throws -> AudioCommentClip in
            try Task.checkCancellation()
            let clip = try AudioCommentClip(data: data)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-audio-validation-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("recording.m4a")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            do {
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let format = file.processingFormat
                guard (file.fileFormat.settings[AVFormatIDKey] as? NSNumber)?.uint32Value == kAudioFormatMPEG4AAC,
                      (1...2).contains(format.channelCount), format.sampleRate.isFinite,
                      (8000...96000).contains(format.sampleRate), file.length > 0,
                      Double(file.length) / format.sampleRate <= 120,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw AudioCommentFailure.invalid }
                var frames: Int64 = 0
                while frames < file.length {
                    try Task.checkCancellation()
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - frames)))
                    if buffer.frameLength == 0 { break }
                    frames += Int64(buffer.frameLength)
                    guard Double(frames) / format.sampleRate <= 120 else { throw AudioCommentFailure.invalid }
                }
                let milliseconds = Double(frames) * 1000 / format.sampleRate
                guard frames > 0, frames == file.length,
                      abs(milliseconds - Double(clip.descriptor.milliseconds)) <= 1000 else { throw AudioCommentFailure.invalid }
                return clip
            } catch is CancellationError { throw CancellationError() }
              catch { throw AudioCommentFailure.invalid }
        }
        return try await withTaskCancellationHandler(operation: {
            let clip = try await worker.value
            try Task.checkCancellation()
            return clip
        }, onCancel: { worker.cancel() })
    }
}
