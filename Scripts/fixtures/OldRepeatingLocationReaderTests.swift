import XCTest
@testable import TaskfoldCore
final class OldRepeatingLocationReaderTests: XCTestCase {
    func document() throws -> [String: JSON] {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "repeating-location", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: file)).object
    }
    func testOpaqueRepeatPreservesEditsRoundTripAndSuccessorWithoutFallback() throws {
        let document = try document(); var task = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(document["task"]!))
        let raw = try XCTUnwrap(ReminderSpec.rows(task).first)
        XCTAssertNil(ReminderSpec(row: raw)); XCTAssertNil(LocationReminderSettings(raw: raw.object)); XCTAssertTrue(DueReminder.events(tasks: [task]).isEmpty)
        task["title"] = .string("Changed title"); XCTAssertTrue(ReminderSpec.setPlanned(false, task: &task))
        let restored = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(restored, task); XCTAssertEqual(ReminderSpec.rows(restored).first, raw); XCTAssertTrue(DueReminder.events(tasks: [restored]).isEmpty)
        let changes = TaskCompletion.complete(restored, tasks: [restored], at: ISO8601DateFormatter().date(from: "2027-01-16T12:00:00Z")!)
        let successor = Record(try XCTUnwrap(changes.first { $0.method == "POST" }).fields)
        XCTAssertNotEqual(successor.id, task.id); XCTAssertEqual(ReminderSpec.rows(successor).first, raw); XCTAssertTrue(DueReminder.events(tasks: [successor]).isEmpty)
    }
    func testNewPrivateRepeatStateIsRefusedWithoutOverwrite() async throws {
        let bytes = try JSONEncoder().encode(document()["archive"]!)
        XCTAssertThrowsError(try LocationPrivateArchive.decode(bytes))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let file = LocationPrivateFile(applicationSupport: root)
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        try bytes.write(to: file.url, options: .atomic)
        let store = LocationPrivateStore(applicationSupport: root)
        do { _ = try await store.snapshot(); XCTFail("Old private reader accepted repeat state") } catch {}
        let pin = try XCTUnwrap(LocationPrivatePlace.make(account: "repeat-local", name: "Other pin", latitude: 55, longitude: 12, radius: 250))
        do { _ = try await store.save(pin); XCTFail("Old writer replaced repeat state") } catch {}
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }
}
