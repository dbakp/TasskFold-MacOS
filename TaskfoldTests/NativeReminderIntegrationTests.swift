import XCTest
@testable import TaskfoldCore

final class NativeReminderIntegrationTests: XCTestCase {
    @MainActor func testTwoAuthenticatedNativeClientsRoundTripReminderChoicesAndDurableQueue() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_REMINDER_LIVE_FIXTURE"] else { throw XCTSkip("Disposable reminder fixture not supplied") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let email = try XCTUnwrap(fixture["email"]), password = try XCTUnwrap(fixture["password"]), owner = try XCTUnwrap(fixture["userID"])
        guard email.hasPrefix("taskfold-reminders-"), email.hasSuffix("@example.invalid"), UUID(uuidString: owner) != nil else { throw AppFailure(message: "Use a disposable reminder fixture account.") }
        let config = ["URL": try XCTUnwrap(fixture["url"]), "Key": try XCTUnwrap(fixture["key"])]
        let a = Backend(configuration: config, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let b = Backend(configuration: config, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let signedA = try await a.signIn(email: email, password: password, signup: false)
        let signedB = try await b.signIn(email: email, password: password, signup: false)
        XCTAssertTrue(signedA && signedB); XCTAssertEqual(a.session?.user.id, owner); XCTAssertEqual(b.session?.user.id, owner)
        XCTAssertNotEqual(a.session?.access_token, b.session?.access_token)
        var task = Record.task(user: owner, date: Date().addingTimeInterval(2 * 86400)); task["title"] = .string("Native reminder fixture")
        task["due_time"] = .string("09:00"); task["time_zone"] = .string("Europe/Copenhagen")
        let relative = ReminderSpec.relative(-30), absolute = ReminderSpec.absolute(Date().addingTimeInterval(3600))
        var extended = relative; extended.raw["future"] = .string("retained")
        let unknown: JSON = .object(["version": .number(2), "id": .string(UUID().uuidString.lowercased()), "provider_extension": .string("keep")])
        task["reminder_specs"] = .array([.object(extended.raw), .object(absolute.raw), unknown])
        func cleanup() async throws {
            let rows = try await a.rows("tasks")
            if let current = rows.first(where: { $0.id == task.id }) {
                try await a.send(Mutation(table: "tasks", recordID: task.id, method: "DELETE", fields: [:], baseline: current.fields))
            }
        }
        try await a.send(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: TaskPlanning.fields(task.fields, existing: nil)))
        do {
            let firstRows = try await b.rows("tasks"), remote = try XCTUnwrap(firstRows.first { $0.id == task.id })
            XCTAssertEqual(remote["reminder_specs"], task["reminder_specs"])
            let initial = DueReminder.events(tasks: [remote])
            XCTAssertEqual(initial.count, 2)
            let fields = TaskPlanning.fields(["due_date": .string(Dates.day(Date().addingTimeInterval(3 * 86400)))], existing: remote)
            try await b.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: fields, baseline: Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, remote[$0]) })))
            let movedRows = try await a.rows("tasks"), moved = try XCTUnwrap(movedRows.first { $0.id == task.id })
            let next = DueReminder.events(tasks: [moved])
            XCTAssertNotEqual(next.first { $0.specID == relative.id }?.date, initial.first { $0.specID == relative.id }?.date)
            XCTAssertEqual(next.first { $0.specID == absolute.id }?.date, initial.first { $0.specID == absolute.id }?.date)
            var edited = moved; XCTAssertTrue(ReminderSpec.append(.relative(15), task: &edited))
            let change = Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["reminder_specs": edited["reminder_specs"]], baseline: ["task_generation": task["task_generation"], "reminder_specs": moved["reminder_specs"]])
            var snapshot = Snapshot(); snapshot.tables["tasks"] = [moved]; snapshot.pending = [change]; snapshot.apply(change)
            let durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
            try await b.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["title": .string("Independent device edit")], baseline: ["task_generation": task["task_generation"], "title": moved["title"]]))
            let queued = try XCTUnwrap(durable.pending.first); try await a.send(queued); try await a.send(queued)
            let finalRows = try await b.rows("tasks"), final = try XCTUnwrap(finalRows.first { $0.id == task.id })
            XCTAssertEqual(final.title, "Independent device edit"); XCTAssertEqual(final["reminder_specs"], edited["reminder_specs"])
            XCTAssertTrue(final["reminder_specs"].list.contains(unknown)); XCTAssertEqual(DueReminder.events(tasks: [final]).count, 3)
            try await b.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["completed": .bool(true)], baseline: ["task_generation": task["task_generation"], "completed": .bool(false), "completion_version": .number(0)]))
            let completedRows = try await a.rows("tasks"), completed = try XCTUnwrap(completedRows.first { $0.id == task.id })
            XCTAssertTrue(DueReminder.events(tasks: [completed]).isEmpty)
        } catch { try? await cleanup(); throw error }
        try await cleanup()
        let remaining = try await b.rows("tasks"); XCTAssertFalse(remaining.contains { $0.id == task.id })
    }
}
