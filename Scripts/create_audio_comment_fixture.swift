import Foundation
import AVFoundation
let path = CommandLine.arguments[1]
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
buffer.frameLength = 44100
for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.04) }
do {
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
    try file.write(from: buffer)
}
print("Encoded one second of synthetic 440 Hz PCM; no microphone or playback used")
