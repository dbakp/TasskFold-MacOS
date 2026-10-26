import XCTest
@testable import TaskfoldCore

final class TaskRootActivityContextTests: XCTestCase {
    let owner = "11111111-1111-4111-8111-111111111111", project = "22222222-2222-4222-8222-222222222222"
    let generation = "abcdef00-3333-4333-8333-333333333333"
    let now = TaskPlanning.instant("2026-10-26T10:00:00Z")!
    func task(heading: Bool = false) -> Record {
        var row = Record.task(user: owner, project: project); row["title"] = .string("Private current title")
        row["description"] = .string("Private current notes"); row["is_heading"] = .bool(heading); row["task_generation"] = .string(generation); return row
    }
    func event(_ before: Record?, _ after: Record?, sequence: Int = 1) throws -> Record {
        let task = try XCTUnwrap(after ?? before)
        let mutation = Mutation(table: "tasks", recordID: task.id, method: before == nil ? "POST" : after == nil ? "DELETE" : "PATCH", fields: after?.fields ?? [:])
        var snapshot = Snapshot()
        TaskActivity.recordLocal(mutation, before: before, after: after, snapshot: &snapshot, account: owner, now: now)
        var row = try XCTUnwrap(snapshot.tables[TaskActivity.table]?.first); row["sequence"] = .number(Double(sequence)); return row
    }
    func completed(_ task: Record) -> Record { var next = task; next["completed"] = .bool(true); next["completed_at"] = .string(TaskActivity.stamp(now)); return next }
    var epoch: [Record] { [Record(["id": .string("current"), "recorded_from": .string("2026-10-01T00:00:00Z")])] }
    func insights(_ rows: [Record]) throws -> InsightsReading { InsightsReading(account: owner, activity: rows, epoch: epoch, goals: try ProductivityGoals(), now: now) }
    func testNewEventsCaptureOnlyActualTypeAndIncarnationWithoutPrivateText() throws {
        let task = task(), row = try event(nil, task), parsed = try XCTUnwrap(TaskActivity(row: row)), metadata = row["root_context"].object
        XCTAssertEqual(parsed.rootContext?.afterType, .task); XCTAssertEqual(parsed.rootContext?.afterGeneration, generation)
        XCTAssertNil(parsed.rootContext?.beforeType); XCTAssertNil(parsed.rootContext?.beforeGeneration)
        XCTAssertFalse(parsed.workBefore); XCTAssertTrue(parsed.workAfter)
        XCTAssertEqual(Set(metadata.keys), ["version", "before_type", "after_type", "before_generation", "after_generation"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(row.fields), as: UTF8.self).contains("Private"))
        XCTAssertEqual(try event(task, nil)["root_context"].object["after_type"], .null)
    }
    func testHeadingEventsAreRetainedWithoutWorkCreditOrAdditions() throws {
        let heading = task(heading: true), ordinary = task()
        let rows = try [event(nil, heading, sequence: 1), event(heading, completed(heading), sequence: 2), event(nil, ordinary, sequence: 3), event(ordinary, completed(ordinary), sequence: 4)]
        let pulse = ProjectPulseReading(project: project, tasks: [], activity: rows, now: now)
        XCTAssertEqual(pulse.events.count, 4); XCTAssertEqual(pulse.additions, 1); XCTAssertEqual(pulse.completions, 1)
        XCTAssertEqual(try insights(rows).today, 1); XCTAssertEqual(try insights(rows).malformed, 0)
        XCTAssertFalse(try XCTUnwrap(TaskActivity(row: rows[1])).workAfter)
    }
    func testMissingMetadataKeepsLegacyCreditsWithoutReadingCurrentType() throws {
        let heading = task(heading: true); var row = try event(heading, completed(heading)); row.fields.removeValue(forKey: "root_context")
        let original = row, parsed = try XCTUnwrap(TaskActivity(row: row))
        XCTAssertNil(parsed.rootContext); XCTAssertTrue(parsed.workAfter); XCTAssertEqual(try insights([row]).today, 1)
        XCTAssertEqual(ProjectPulseReading(project: project, tasks: [heading], activity: [row], now: now).completions, 1)
        XCTAssertEqual(row, original)
    }
    func testCapturedTypeIsNotReinterpretedWhenCurrentRootChanges() throws {
        let ordinary = task(), row = try event(ordinary, completed(ordinary)); var current = ordinary; current["is_heading"] = .bool(true)
        XCTAssertEqual(ProjectPulseReading(project: project, tasks: [current], activity: [row], now: now).completions, 1)
        let heading = task(heading: true), headingRow = try event(heading, completed(heading)); var currentTask = heading; currentTask["is_heading"] = .bool(false)
        XCTAssertEqual(ProjectPulseReading(project: project, tasks: [currentTask], activity: [headingRow], now: now).completions, 0)
    }
    func testMetadataVersionShapeTypesAndIncarnationsFailClosed() throws {
        let ordinary = task(), valid = try event(ordinary, completed(ordinary))
        for edit: [String: JSON] in [["version": .number(2)], ["after_type": .string("future")], ["after_generation": .string("invalid")], ["before_type": .null], ["before_generation": .null], ["private_title": .string("Never store this")]] {
            var row = valid; row["root_context"] = .object(valid["root_context"].object.merging(edit) { _, value in value })
            XCTAssertNil(TaskActivity(row: row), edit.description)
            let snapshot = Snapshot(tables: [TaskActivity.table: [row]]), original = snapshot
            XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data()))
            XCTAssertEqual(snapshot, original)
        }
        var upper = valid; var meta = valid["root_context"].object; meta["after_generation"] = .string(generation.uppercased()); upper["root_context"] = .object(meta)
        XCTAssertEqual(TaskActivity(row: upper)?.rootContext?.afterGeneration, generation)
    }
    func testUnknownTypeIsUnreliableAndIncarnationResetIsNotACompletion() throws {
        let task = task(); var row = try event(task, completed(task)); var metadata = row["root_context"].object
        metadata["after_type"] = .string("unknown"); row["root_context"] = .object(metadata)
        var pulse = ProjectPulseReading(project: project, tasks: [], activity: [row], now: now)
        XCTAssertEqual(pulse.completions, 0); XCTAssertEqual(pulse.malformed, 1); XCTAssertFalse(try insights([row]).reliable)
        metadata["after_type"] = .string("task"); metadata["after_generation"] = .string(UUID().uuidString.lowercased()); row["root_context"] = .object(metadata)
        pulse = ProjectPulseReading(project: project, tasks: [], activity: [row], now: now)
        XCTAssertTrue(try XCTUnwrap(TaskActivity(row: row)).rootContext!.generationChanged); XCTAssertEqual(pulse.completions, 0); XCTAssertEqual(pulse.malformed, 0)
        XCTAssertEqual(try insights([row]).today, 0); XCTAssertTrue(try insights([row]).reliable)
    }
    func testTypedRootRouteCannotOpenRecreatedTransferredDuplicateOrLegacyOccurrence() throws {
        let task = task(), event = try XCTUnwrap(TaskActivity(row: try event(task, completed(task))))
        let projects = [Record(["id": .string(project), "name": .string("Studio")])]
        func route(_ tasks: [Record]) -> Record? { ProjectActivityContext(event: event, project: project, tasks: tasks, projects: projects, members: [], account: owner).task }
        XCTAssertEqual(route([task])?.id, task.id)
        var replaced = task; replaced["task_generation"] = .string(UUID().uuidString.lowercased()); XCTAssertNil(route([replaced]))
        replaced = task; replaced["user_id"] = .string("other"); XCTAssertNil(route([replaced])); XCTAssertNil(route([task, task]))
        var legacy = task; legacy["task_generation"] = .null
        let oldEvent = try XCTUnwrap(TaskActivity(row: try self.event(legacy, completed(legacy))))
        XCTAssertNil(ProjectActivityContext(event: oldEvent, project: project, tasks: [legacy], projects: projects, members: [], account: owner).task)
    }
    func testMetadataIsArchivedLosslesslyButNeverReplayedOrRemapped() throws {
        let task = task(), row = try event(task, completed(task)), snapshot = Snapshot(tables: [TaskActivity.table: [row]])
        let archive = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: owner).data())
        XCTAssertEqual(archive.tables[TaskActivity.table], [row]); XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let plan = try archive.plan(current: Snapshot(), account: UUID().uuidString.lowercased())
        XCTAssertTrue(plan.changes.isEmpty); XCTAssertTrue(plan.warnings.contains { $0.contains("archive") })
    }
    func testTypeOnlyEditCreatesNoFictionalLegacyEventAndKeepsSourceIntact() {
        let before = task(heading: true); var after = before; after["is_heading"] = .bool(false)
        let change = Mutation(table: "tasks", recordID: after.id, method: "PATCH", fields: ["is_heading": .bool(false)])
        var snapshot = Snapshot(tables: ["tasks": [after]])
        TaskActivity.recordLocal(change, before: before, after: after, snapshot: &snapshot, account: owner, now: now)
        XCTAssertNil(snapshot.tables[TaskActivity.table]); XCTAssertEqual(snapshot.tables["tasks"], [after])
    }
    func testActualPostgresUpgradeRowsDecodeAsLegacyOrObservedContext() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "task-root-activity", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        let events = try rows.map { try XCTUnwrap(TaskActivity(row: $0), $0.id) }
        XCTAssertGreaterThan(events.count, 5); XCTAssertTrue(events.contains { $0.rootContext == nil })
        XCTAssertTrue(events.contains { $0.rootContext?.afterType == .heading && $0.kinds == [.completed] && !$0.workAfter })
        XCTAssertTrue(events.contains { $0.rootContext?.generationChanged == true })
        XCTAssertTrue(events.contains { $0.kinds == [.deleted] && $0.rootContext?.afterGeneration == nil })
    }
    func testWidgetHistoryUsesObservedWorkAndFlagsUnclassifiableRows() throws {
        let task = task(heading: true), row = try event(task, completed(task)), projects = [Record(["id": .string(project), "name": .string("Studio")])]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        func payload(_ rows: [Record]) throws -> ProjectPulseSnapshot {
            let json = WidgetProjection.pulsePayload(tasks: [], projects: projects, activity: rows, epoch: epoch, account: owner, readable: true, now: now, calendar: calendar)
            return try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONEncoder().encode(json))
        }
        let classified = try payload([row]); XCTAssertEqual(classified.history, "ready")
        XCTAssertTrue(classified.projects.allSatisfy { $0.days.values.allSatisfy { $0.completions == 0 } })
        var unknown = row; var metadata = row["root_context"].object; metadata["after_type"] = .string("unknown"); unknown["root_context"] = .object(metadata)
        XCTAssertEqual(try payload([unknown]).history, "incomplete")
    }

    func testKnownNewIncarnationResetsCountersAndRetainsEarlierRecordedWorkOnce() throws {
        let original = task(); var done = completed(original); done["completion_version"] = .number(40)
        var next = done; next["task_generation"] = .string(UUID().uuidString.lowercased()); next["due_date"] = .string("2026-10-27"); next["completion_version"] = .number(0)
        var open = next; open["completed"] = .bool(false); open["completed_at"] = .null; open["completion_version"] = .number(1)
        var newDone = completed(open); newDone["completion_version"] = .number(2)
        let rows = try [event(nil, original, sequence: 1), event(original, done, sequence: 2), event(done, next, sequence: 3), event(next, open, sequence: 4), event(open, newDone, sequence: 5)]
        let result = try insights(rows)
        XCTAssertTrue(result.reliable); XCTAssertEqual(result.today, 2); XCTAssertEqual(Set(result.credits.map(\.lifecycle)).count, 2)
        XCTAssertEqual(try insights(Array(rows.prefix(3))).today, 1)
    }

    func testUnsupportedSourceIdentityRetainsTheActualEventWithoutInventedWorkOrRepair() throws {
        var task = task(); task["task_generation"] = .string("unsupported source identity"); let original = task
        let row = try event(task, completed(task)), parsed = try XCTUnwrap(TaskActivity(row: row))
        XCTAssertEqual(parsed.kinds, [.completed]); XCTAssertEqual(parsed.rootContext?.afterType, .unknown)
        XCTAssertFalse(parsed.workAfter); XCTAssertEqual(try insights([row]).today, 0); XCTAssertFalse(try insights([row]).reliable)
        XCTAssertEqual(task, original)
    }

}
