import Foundation
import FoundationModels
@available(macOS 26, *)
@Generable private struct PatternFilterControl {
    @Guide(.anyOf(["p1", "p2", "p3", "p4"])) var expression: String
}
@main struct Probe {
    static func main() async throws {
        let output = CommandLine.arguments[1]
        precondition(output.hasPrefix("/tmp/taskfold-") && output.hasSuffix(".json") && !FileManager.default.fileExists(atPath: output))
        var report: [String: Any] = ["scope": "One synthetic finite-choice guide control; no regex, settings change or filter-quality acceptance", "os": ProcessInfo.processInfo.operatingSystemVersionString, "requests": 0]
        if #available(macOS 26, *) {
            report["availability"] = String(reflecting: SystemLanguageModel.default.availability)
            guard case .available = SystemLanguageModel.default.availability else {
                report["notRun"] = true
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic); return
            }
            report["schema"] = String(reflecting: PatternFilterControl.generationSchema)
            let session = LanguageModelSession(instructions: "Return p3 as the expression. No other words.")
            report["requests"] = 1
            do {
                let expression = try await session.respond(to: "Priority three", generating: PatternFilterControl.self, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64)).content.expression
                report["expression"] = expression; report["generationSucceeded"] = true
            } catch {
                var detail = ""; dump(error, to: &detail)
                report["generationSucceeded"] = false
                report["errorType"] = String(reflecting: type(of: error))
                report["errorReflection"] = String(reflecting: error)
                report["errorStructure"] = String(detail.prefix(8_000)).replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
