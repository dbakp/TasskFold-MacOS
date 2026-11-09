import XCTest
@testable import TaskfoldCore

extension LocationTaskDraftTests {
    func testRetirementScanKeepsDisabledOriginalAndDuplicateIdentityCancellation() throws {
        let (initial, task, ticket) = try retirementFixture()
        var disabled = task
        disabled["reminder_specs"] = .array(ReminderSpec.rows(task).map { row in
            guard let setting = LocationReminderSettings(raw: row.object) else { return row }
            return .object(setting.settingEnabled(false).raw)
        })
        for original in [task, disabled] {
            var before = initial; before.tables["tasks"] = [original]
            var removed = original; removed["reminder_specs"] = .array([])
            for rows in [[], [removed], [original, original]] as [[Record]] {
                let proposed = Snapshot(tables: ["tasks": rows])
                let saved = try LocationRetirementOutbox.staging(previous: before, proposed: proposed, account: account)
                XCTAssertEqual(saved.locationRetirements, [ticket.identifier: ticket])
                XCTAssertEqual(saved.tables, proposed.tables)
            }
        }
    }

    func testUnrelatedTaskChangesKeepSavedCancellationUntilExplicitAcknowledgement() throws {
        let (_, _, ticket) = try retirementFixture()
        let task = Record(["id": .string("plain"), "title": .string("Cafe\u{301}"), "opaque": .object(["future": .array([.bool(false), .number(-0.0)])])])
        var before = Snapshot(tables: ["tasks": [task]]); before.locationRetirements = [ticket.identifier: ticket]
        var changed = task; changed["title"] = .string("Another title")
        let proposed = Snapshot(tables: ["tasks": [changed]])
        let saved = try LocationRetirementOutbox.staging(previous: before, proposed: proposed, account: account)
        XCTAssertEqual(saved.locationRetirements, before.locationRetirements)
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(saved.tables), try encoder.encode(proposed.tables))
        XCTAssertNil(try LocationRetirementOutbox.staging(previous: saved, proposed: proposed, account: account, acknowledged: [ticket]).locationRetirements)
    }

    func testUnknownAndMalformedReminderRowsDoNotInventRetirements() throws {
        for value in [JSON.null, .object(["kind": .string("location")]), .array([.object(["kind": .string("location"), "version": .number(99)]), .object(["kind": .bool(true)]), .object(ReminderSpec.relative(-30).raw)])] {
            var task = Record.task(user: account); task["reminder_specs"] = value
            let before = Snapshot(tables: ["tasks": [task]])
            let saved = try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(), account: account)
            XCTAssertNil(saved.locationRetirements)
        }
    }

    func testRetirementSaveStageTimingDiagnostic() throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_RETIREMENT_TIMING"] == "1" else { throw XCTSkip("Optional component timing") }
        let place = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Synthetic", latitude: 55, longitude: 12, radius: 250, id: device, revision: device))
        var results: [[String: Any]] = []
        for mode in ["unchanged", "no-location", "one-location", "all-location"] {
            let rows: [Record] = try (0..<2000).map { index in
                let id = String(format: "95100000-0000-4000-8000-%012d", index)
                var row = Record(["id": .string(id), "title": .string("Synthetic task \(index)"), "task_generation": .string(device), "description": .string(String(repeating: "Notes é ", count: 128)), "subtasks": .array([.object(["id": .string("nested"), "title": .string("Keep these instructions")])])])
                if mode == "all-location" || mode == "one-location" && index == 1000 {
                    let setting = try XCTUnwrap(LocationReminderSettings.make(device: device, taskID: id, taskGeneration: device, place: place, transition: .arrive, id: device, arm: device))
                    row["reminder_specs"] = .array([.object(setting.raw)])
                }
                return row
            }
            let previous = Snapshot(tables: ["tasks": rows]); var changed = rows
            if mode != "unchanged" { changed[1500]["title"] = .string("Edited synthetic task") }
            let proposed = Snapshot(tables: ["tasks": changed])
            _ = try LocationRetirementOutbox.staging(previous: previous, proposed: proposed, account: account)
            var samples: [Double] = []
            for _ in 0..<7 {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<5 {
                    let result = try LocationRetirementOutbox.staging(previous: previous, proposed: proposed, account: account)
                    XCTAssertNil(result.locationRetirements)
                }
                samples.append((ProcessInfo.processInfo.systemUptime - start) / 5)
            }
            results.append(["mode": mode, "rows": rows.count, "seconds": samples, "medianSeconds": samples.sorted()[3]])
        }
        if let output = ProcessInfo.processInfo.environment["TASKFOLD_RETIREMENT_TIMING_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: ["componentOnly": true, "samples": results], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
