import XCTest
@testable import TaskfoldCore
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, iOS 26, *)
@Generable private struct PlainFilterControl { var expression: String }
@available(macOS 26, iOS 26, *)
@Generable private struct PatternFilterControl {
    @Guide(.pattern(try! Regex("p[1-4]"))) var expression: String
}
#endif

final class FilterGuidanceControlTests: XCTestCase {
    func testActualGenerationControlsWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_TEST_ON_DEVICE_MODEL"] == "1" else { throw XCTSkip("Synthetic model controls are opt-in") }
        if let reason = OnDeviceAssistance.unavailableReason { throw XCTSkip(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            for constrained in [false, true] {
                let session = LanguageModelSession(instructions: "Return p3 as the expression. No other words.")
                do {
                    let expression: String
                    if constrained {
                        expression = try await session.respond(to: "Priority three", generating: PatternFilterControl.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64)).content.expression
                    } else {
                        expression = try await session.respond(to: "Priority three", generating: PlainFilterControl.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64)).content.expression
                    }
                    print("FILTER_GUIDANCE_CONTROL " + String(data: try JSONSerialization.data(withJSONObject: ["pattern": constrained, "expression": expression], options: [.sortedKeys]), encoding: .utf8)!)
                    XCTAssertEqual(expression, "p3")
                } catch {
                    let failure = error as NSError
                    let details: [String: Any] = ["pattern": constrained, "errorDomain": failure.domain, "errorCode": failure.code, "message": failure.localizedDescription, "debug": failure.userInfo[NSDebugDescriptionErrorKey] as? String ?? ""]
                    print("FILTER_GUIDANCE_CONTROL " + String(data: try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]), encoding: .utf8)!)
                    XCTFail("Synthetic generation control failed")
                }
            }
        }
        #endif
    }
}
