import XCTest
@testable import TaskfoldCore

final class WidgetCompletionPreparationTests: XCTestCase {
    // These are the persisted signature rules from before parser reuse. Keep the
    // independent reference to detect accidental token invalidation on upgrade.
    private func legacyInstant(_ value: String) -> String {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return fractional.string(from: date)
    }
    private let dates = ["", "2026-10-27T12:34:56Z", "2026-10-27T12:34:56.123Z", "2026-10-27T13:34:56+01:00", "2026-10-27T07:04:56.123-05:30", "2026-10-25T02:30:00+02:00", "2026-10-25T02:30:00+01:00", "2026-03-29T02:30:00+01:00", "2024-02-29T23:59:59.999Z", "2026-10-27", "not a date", "2026-13-99T99:99:99Z", " 2026-10-27T12:34:56Z ", "2026-10-27T12:34:56.123456Z", "bad-\u{00e9}", "bad-e\u{0301}"]
    private func tasks(count: Int, dateOffset: Int = 0) -> [Record] {
        (0..<count).map { index in
            var row = Record(["id": .string(String(format: "a7100000-0000-4000-8000-%012x", index + 1)), "user_id": .string("a7200000-0000-4000-8000-000000000001"), "title": .string("Token proof \(index)"), "completed": .bool(index % 3 == 0), "created_at": .string(dates[(index + dateOffset) % dates.count]), "completed_at": .string(dates[(index * 3 + dateOffset) % dates.count]), "completion_version": index % 4 == 0 ? .null : .number(Double(index % 7)), "is_heading": index % 5 == 0 ? .null : .bool(false)])
            if index % 2 == 0 { row["task_generation"] = .string("a7300000-0000-4000-8000-000000000001") }
            return row
        }
    }
    private func signatures(_ rows: [Record], canonical supplied: [String: String]? = nil) throws -> [String: String] {
        let canonical: [Data: String] = supplied.map { Dictionary(uniqueKeysWithValues: $0.map { (Data($0.key.utf8), $0.value) }) } ?? Dictionary(uniqueKeysWithValues: dates.map { (Data($0.utf8), legacyInstant($0)) })
        return Dictionary(uniqueKeysWithValues: try rows.map { task in
            var fields: [JSON] = [.bool(task.completed), .string(try XCTUnwrap(canonical[Data(task.string("created_at").utf8)])), .string(try XCTUnwrap(canonical[Data(task.string("completed_at").utf8)])), task["completion_version"], task["is_heading"]]
            if !task.string("task_generation").isEmpty { fields.append(task["task_generation"]) }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(fields)
            return (task.id.lowercased(), DueReminder.digest(String(decoding: data, as: UTF8.self)))
        })
    }
    func testFullSizePreparationRetainsEveryLegacyTokenAndSignature() throws {
        let rows = tasks(count: 5000), expected = try signatures(rows)
        var snapshot = Snapshot(tables: ["tasks": rows])
        snapshot.widgetCompletion.states = expected.mapValues { WidgetCompletionCache.State(token: UUID().uuidString.lowercased(), signature: $0) }
        let original = snapshot.widgetCompletion.states
        snapshot.widgetCompletion.receipts = ["receipt": rows[0].id]; snapshot.widgetCompletion.receiptOrder = ["receipt"]
        snapshot.widgetCompletion.states["obsolete"] = .init(token: "obsolete", signature: "obsolete")
        let start = ContinuousClock.now
        WidgetCompletion.prepare(&snapshot)
        let elapsed = start.duration(to: .now)
        print("WIDGET_PREPARE_5000_SECONDS \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
        XCTAssertEqual(snapshot.widgetCompletion.states, original)
        XCTAssertEqual(snapshot.widgetCompletion.receipts, ["receipt": rows[0].id]); XCTAssertEqual(snapshot.widgetCompletion.receiptOrder, ["receipt"])
        WidgetCompletion.prepare(&snapshot)
        XCTAssertEqual(snapshot.widgetCompletion.states, original)
    }
    func testFiveThousandDistinctInstantsKeepCanonicalSignaturesAndTokens() throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date(timeIntervalSince1970: 1767225600)
        var rows = tasks(count: 5000), known: [String: String] = ["": ""]
        for index in rows.indices {
            let value = formatter.string(from: start.addingTimeInterval(Double(index) * 123.125))
            rows[index]["created_at"] = .string(value); rows[index]["completed_at"] = .null
            known[value] = value // Already canonical UTC fractional spelling.
        }
        XCTAssertEqual(known.count, 5001)
        let expected = try signatures(rows, canonical: known)
        var snapshot = Snapshot(tables: ["tasks": rows])
        let started = ContinuousClock.now
        WidgetCompletion.prepare(&snapshot)
        let elapsed = started.duration(to: .now)
        print("WIDGET_PREPARE_5000_DISTINCT_SECONDS \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
        XCTAssertEqual(snapshot.widgetCompletion.states.mapValues(\.signature), expected)
        let original = snapshot.widgetCompletion.states
        snapshot.tables["tasks"] = rows.reversed()
        WidgetCompletion.prepare(&snapshot)
        XCTAssertEqual(snapshot.widgetCompletion.states, original)
    }
    func testEquivalentTimestampSpellingKeepsTokenButNewInstantRotatesIt() throws {
        var row = tasks(count: 1)[0]; row["created_at"] = .string("2026-10-27T12:34:56Z"); row["completed_at"] = .null
        var snapshot = Snapshot(tables: ["tasks": [row]])
        WidgetCompletion.prepare(&snapshot); let original = snapshot.widgetCompletion.states[row.id]
        row["created_at"] = .string("2026-10-27T13:34:56.000+01:00"); snapshot.tables["tasks"] = [row]
        WidgetCompletion.prepare(&snapshot); XCTAssertEqual(snapshot.widgetCompletion.states[row.id], original)
        row["created_at"] = .string("2026-10-27T12:34:56.001Z"); snapshot.tables["tasks"] = [row]
        WidgetCompletion.prepare(&snapshot); XCTAssertNotEqual(snapshot.widgetCompletion.states[row.id]?.token, original?.token)
    }
    func testHeadingRootRetainsLegacySignatureAndExistingChildToken() throws {
        var root = tasks(count: 1)[0]
        root["is_heading"] = .bool(true); root["completed"] = .bool(false)
        root["created_at"] = .string(dates[1]); root["completed_at"] = .null
        root["subtasks"] = .array([.object(["id": .string("a7400000-0000-4000-8000-000000000001"), "title": .string("Review the layout"), "completed": .bool(false)])])
        let expected = try signatures([root])
        var snapshot = Snapshot(tables: ["tasks": [root]])
        WidgetCompletion.prepare(&snapshot)
        XCTAssertEqual(snapshot.widgetCompletion.states[root.id]?.signature, expected[root.id])
        XCTAssertEqual(snapshot.widgetCompletion.states.count, 2, "The productive child must retain its own actionable token")
        let original = snapshot.widgetCompletion.states
        root["title"] = .string("Updated reference title"); snapshot.tables["tasks"] = [root]
        WidgetCompletion.prepare(&snapshot)
        XCTAssertEqual(snapshot.widgetCompletion.states, original)
    }
    func testInvalidCanonicallyEquivalentStringsKeepExactSignatureBytes() throws {
        let composed = "bad-\u{00e9}", decomposed = "bad-e\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        var rows = tasks(count: 2)
        for index in rows.indices {
            rows[index]["created_at"] = .string(index == 0 ? composed : decomposed)
            rows[index]["completed_at"] = .null; rows[index]["completed"] = .bool(false)
            rows[index]["completion_version"] = .number(0); rows[index]["is_heading"] = .null
            rows[index]["task_generation"] = .null
        }
        let expected = try signatures(rows)
        XCTAssertNotEqual(expected[rows[0].id], expected[rows[1].id])
        var snapshot = Snapshot(tables: ["tasks": rows]); WidgetCompletion.prepare(&snapshot)
        XCTAssertEqual(snapshot.widgetCompletion.states.mapValues(\.signature), expected)
    }
    func testEncoderFailureDoesNotPolluteFollowingRootSignature() throws {
        var rows = tasks(count: 2); let expected = try signatures([rows[1]])
        rows[0]["completion_version"] = .number(.infinity)
        var snapshot = Snapshot(tables: ["tasks": rows]); WidgetCompletion.prepare(&snapshot)
        XCTAssertEqual(snapshot.widgetCompletion.states[rows[0].id]?.signature, "")
        XCTAssertEqual(snapshot.widgetCompletion.states[rows[1].id]?.signature, expected[rows[1].id])
    }
    func testSimultaneousIndependentSavesKeepTheirOwnCanonicalization() async throws {
        let first = tasks(count: 500), second = tasks(count: 500, dateOffset: 3)
        let expectedFirst = try signatures(first), expectedSecond = try signatures(second)
        async let a = Task.detached { var value = Snapshot(tables: ["tasks": first]); WidgetCompletion.prepare(&value); return value.widgetCompletion.states.mapValues(\.signature) }.value
        async let b = Task.detached { var value = Snapshot(tables: ["tasks": second]); WidgetCompletion.prepare(&value); return value.widgetCompletion.states.mapValues(\.signature) }.value
        let (one, two) = await (a, b)
        XCTAssertEqual(one, expectedFirst); XCTAssertEqual(two, expectedSecond); XCTAssertNotEqual(one, two)
    }
}
