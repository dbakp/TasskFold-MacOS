import XCTest
@testable import TaskfoldCore

/// Both native clients and the candidate SQL planner consume the same, independently
/// expected civil dates/identities. This is not acceptance of task API writes.
final class AutomationRecurrenceParityTests: XCTestCase {
    func testCandidateServerPlanMatchesNativeCompletionContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "automation-recurrence", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([JSON].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixtures.count, 300)
        for fixture in fixtures {
            let name = fixture.object["name"]!.text
            let task = Record(fixture.object["task"]!.object)
            let stamp = try XCTUnwrap(ISO8601DateFormatter().date(from: fixture.object["completed_at"]!.text), name)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: fixture.object["input_zone"]!.text), name)
            let changes = TaskCompletion.complete(task, tasks: [task], at: stamp, calendar: calendar)
            let expected = fixture.object["expected"]!
            let successors = changes.filter { $0.method == "POST" }
            if expected == .null {
                XCTAssertTrue(successors.isEmpty, name)
            } else {
                let successor = try XCTUnwrap(successors.first, name)
                XCTAssertEqual(successors.count, 1, name)
                XCTAssertEqual(successor.fields["due_date"], expected.object["due_date"], name)
                XCTAssertEqual(successor.recordID, expected.object["id"]!.text, name)
                XCTAssertEqual(successor.fields["recurrence_pattern"], expected.object["recurrence_pattern"], name)
                XCTAssertEqual(successor.insertOnly, true, name)
            }
        }
    }
}
