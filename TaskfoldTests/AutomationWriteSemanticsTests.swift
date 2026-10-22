import XCTest
@testable import TaskfoldCore

/// Cross-language golden inputs/outputs for full successor data, wall clocks and
/// defaults. Ordinary runs only read. The explicit maintainer export writes
/// synthetic deterministic goldens to the provided path, never an app container.
final class AutomationWriteSemanticsTests: XCTestCase {
    private func calendar(_ zone: String) throws -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return result
    }
    private func normalized(_ value: JSON, field: String = "") -> JSON {
        switch value {
        case .object(let fields): return .object(fields.reduce(into: [:]) { $0[$1.key] = normalized($1.value, field: $1.key) })
        case .array(let rows): return .array(rows.map { normalized($0) })
        case .string(let text) where ["created_at", "completed_at", "scheduled_at", "notification_sent_at"].contains(field):
            guard let instant = TaskPlanning.instant(text) else { return value }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .string(formatter.string(from: instant))
        default: return value
        }
    }
    func testNativeWriteSemanticsGoldenContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "automation-write-semantics", withExtension: "json", subdirectory: "Fixtures"))
        var document = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url)).object
        let export = ProcessInfo.processInfo.environment["TASKFOLD_WRITE_SEMANTICS_EXPORT"]
        XCTAssertEqual(document["wall_times"]?.list.count, 11)
        for row in document["wall_times"]!.list {
            let fields = row.object, name = fields["name"]!.text
            let result = TaskPlanning.start(Record(fields["task"]!.object), calendar: try calendar(fields["input_zone"]!.text))
            let expected = fields["expected"] == .null ? nil : TaskPlanning.instant(fields["expected"]!.text)
            XCTAssertEqual(result, expected, name)
        }
        document["automatic_reminders"] = .array(try document["automatic_reminders"]!.list.map { row in
            var fields = row.object
            let task = Record(fields["task"]!.object), previous = fields["previous"] == .null ? nil : Record(fields["previous"]!.object)
            let minutes = fields["minutes"] == .null ? nil : fields["minutes"]!.integer
            let c = try calendar(fields["input_zone"]!.text)
            let actual = minutes.map { ReminderAutomatic.applying(to: task, previous: previous, minutes: $0, calendar: c) } ?? task
            let result = normalized(.object(actual.fields))
            if export != nil { fields["expected"] = result }
            else { XCTAssertEqual(result, fields["expected"], fields["name"]!.text) }
            return .object(fields)
        })
        document["successors"] = .array(try document["successors"]!.list.map { row in
            var fields = row.object
            let source = Record(fields["task"]!.object), at = try XCTUnwrap(TaskPlanning.instant(fields["completed_at"]!.text))
            let changes = TaskCompletion.complete(source, tasks: [source], at: at, calendar: try calendar(fields["input_zone"]!.text), account: fields["account"]!.text)
            var result: JSON = .null
            if var next = changes.first(where: { $0.method == "POST" })?.fields {
                next["task_generation"] = fields["generation"]!
                var metadata = next["source_metadata"]!.object
                metadata["taskfold_recurrence_v1"] = .object(["action_id": fields["action"]!])
                next["source_metadata"] = .object(metadata)
                result = normalized(.object(next))
            }
            if export != nil { fields["expected"] = result }
            else { XCTAssertEqual(result, fields["expected"], fields["name"]!.text) }
            return .object(fields)
        })
        if let export {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(JSON.object(document)).write(to: URL(fileURLWithPath: export), options: .atomic)
        }
    }
}
