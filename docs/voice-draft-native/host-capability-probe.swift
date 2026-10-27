import Foundation
import Speech
import AVFoundation
let locales = ["en-US", "en-GB", "es-ES", "da-DK"]
let rows: [[String: Any]] = locales.map { identifier in
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
    return ["locale": identifier, "recognizerExists": recognizer != nil, "supportsOnDevice": recognizer?.supportsOnDeviceRecognition ?? false, "available": recognizer?.isAvailable ?? false]
}
let value: [String: Any] = ["speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue, "microphoneAuthorization": AVCaptureDevice.authorizationStatus(for: .audio).rawValue, "locales": rows, "scope": "Read-only host capability probe; no permission request or recording"]
let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
print(String(decoding: bytes, as: UTF8.self))
