import XCTest
@testable import TaskfoldCore

/// Actual native readers produce the portable-kind oracle, independently of SQL.
/// Optional export writes only this deterministic synthetic fixture, not app data.
final class AutomationReminderValidationTests: XCTestCase {
    func testNativePortableReminderValidationGoldenContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "automation-reminder-validation", withExtension: "json", subdirectory: "Fixtures"))
        var document = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url)).object
        let export = ProcessInfo.processInfo.environment["TASKFOLD_REMINDER_VALIDATION_EXPORT"]
        let rows = try XCTUnwrap(document["cases"]?.list)
        XCTAssertGreaterThan(rows.count, 100)
        document["cases"] = .array(rows.map { row in
            var fields = row.object
            let spec = ReminderSpec(row: fields["spec"]!)
            let actual = spec.map { JSON.string($0.kind) } ?? .null
            if export != nil { fields["expected"] = actual }
            else { XCTAssertEqual(actual, fields["expected"], fields["name"]!.text) }
            return .object(fields)
        })
        if let export {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(JSON.object(document)).write(to: URL(fileURLWithPath: export), options: .atomic)
        }
    }
}
