import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Both assistants use only the system on-device model, without a cloud fallback.
enum OnDeviceAssistance {
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return SystemLanguageModel.default.supportsLocale() ? nil : "Apple Intelligence doesn’t support the current language for suggestions. You can still edit manually."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in system settings to use on-device suggestions."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still getting ready. Try again after its model finishes downloading."
            case .unavailable(.deviceNotEligible):
                return "This device doesn’t support on-device suggestions. You can still edit manually."
            @unknown default:
                return "On-device suggestions aren’t available right now. Try again later."
            }
        }
        #endif
        return "On-device suggestions require iOS 26 or macOS 26 and Apple Intelligence."
    }
}
