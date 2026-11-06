import XCTest
@testable import TaskfoldCore
final class OldHolidayReaderTests: XCTestCase {
    func testUnknownHolidayPoliciesAndPresentationWrappersArePreservedWithoutAlerts() throws {
        let holiday: JSON = .object(["version": .number(5), "id": .string("11000000-0000-4000-8000-000000000001"), "kind": .string("recurring"), "enabled": .bool(true), "channels": .array([.string("local")]), "start_day": .string("2027-01-01"), "time": .string("09:00"), "time_zone": .string("UTC"), "recurrence": .object(["type": .string("daily"), "count": .number(3)]), "holiday_policy": .object(["version": .number(1), "year": .number(2027), "mode": .string("skip"), "avoid_weekends": .bool(false), "origin": .object(["provider": .string("nager-v4"), "country": .string("DE"), "subdivision": .string("DE-BY")]), "source": .string("Synthetic holidays"), "region": .string("Workshop"), "digest": .string(String(repeating: "a", count: 64)), "dates": .array([.string("2027-01-01")])])])
        var wrapped = holiday.object; wrapped["version"] = .number(4); wrapped["schedule_version"] = .number(5); wrapped["presentation"] = .string("time-sensitive")
        for raw in [holiday, .object(wrapped)] {
            XCTAssertNil(ReminderSpec(row: raw))
            var task = Record(["id": .string(UUID().uuidString), "title": .string("Previous reader"), "due_date": .string("2027-01-01"), "is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")]), "reminder_specs": .array([raw])])
            XCTAssertTrue(DueReminder.events(tasks: [task]).isEmpty)
            task["title"] = .string("Changed title"); XCTAssertTrue(ReminderSpec.setPlanned(false, task: &task))
            let saved = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(task))
            XCTAssertEqual(ReminderSpec.rows(saved).first, raw); XCTAssertEqual(ReminderSpec.rows(TaskPlanning.nextOccurrence(saved, date: Date())).first, raw)
            XCTAssertTrue(DueReminder.events(tasks: [saved]).isEmpty)
        }
    }
}
