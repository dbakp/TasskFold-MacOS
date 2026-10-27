import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class ProjectPulseWidgetTests: XCTestCase {
    let owner = "owner", other = "other", projectID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71"
    let now = TaskPlanning.instant("2026-10-06T10:00:00Z")!
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    func project(_ id: String? = nil, name: String = "Studio") -> Record { Record(["id": .string(id ?? projectID), "name": .string(name), "user_id": .string(owner)]) }
    func task(_ id: String = "task", done: Bool = false) -> Record {
        var t = Record.task(user: owner, project: projectID); t["id"] = .string(id); t["title"] = .string("Useful draft"); t["description"] = .string("PRIVATE FULL NOTES"); t["completed"] = .bool(done); return t
    }
    func sample() -> Snapshot {
        var t = task(); t["deadline_date"] = .string("2026-10-06")
        var s = Snapshot(tables: ["projects": [project()], "tasks": [t]])
        for index in 0..<3 {
            let before = s.tables["tasks"]![0]
            let change = Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: ["completed": .bool(index != 1), "completed_at": index == 1 ? .null : .string(TaskActivity.stamp(now.addingTimeInterval(-Double(3-index) * 60)))])
            s.apply(change); TaskActivity.recordLocal(change, before: before, after: s.tables["tasks"]![0], snapshot: &s, account: owner, now: now.addingTimeInterval(-Double(3-index) * 60))
        }
        var attention = task("attention"); attention["deadline_date"] = .string("2026-10-06")
        s.tables["tasks"]!.append(attention); return s
    }
    func widget(_ s: Snapshot, readable: Bool = true, at: Date? = nil, account: String? = nil) throws -> WidgetSnapshot {
        let payload = WidgetProjection.payload(tasks: s.tables["tasks"] ?? [], projects: s.tables["projects"] ?? [], account: account ?? owner, now: at ?? now, calendar: calendar, focusReadable: readable, pulseActivity: s.tables[TaskActivity.table] ?? [], pulseEpoch: s.tables[TaskActivity.epochTable] ?? [])
        return try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
    }
    func testPulseProjectionRetainsFrozenHistoryAndBoundaryCorpus() throws {
        let account = "11111111-1111-4111-8111-111111111111", second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb72"
        let instants = ["2026-03-29T01:30:00Z", "2026-10-25T01:30:00Z"]
        var digests: [String] = []
        for zone in ["Europe/Copenhagen", "America/New_York", "Asia/Kathmandu", "Pacific/Apia"] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            for variant in 0..<16 {
                let now = try XCTUnwrap(TaskPlanning.instant(instants[variant % 2]))
                let open = Record(["id": .string("root"), "title": .string("Private task"), "project_id": .string(projectID), "completed": .bool(false), "task_generation": .string("cccccccc-cccc-4ccc-8ccc-cccccccccc73")])
                var done = open; done["completed"] = .bool(true); done["completed_at"] = .string(TaskActivity.stamp(now.addingTimeInterval(-60)))
                var moved = done; moved["project_id"] = .string(second)
                func event(_ number: Int, _ before: Record?, _ after: Record?, _ date: Date) -> Record {
                    let b = before.map(TaskActivity.state) ?? [:], a = after.map(TaskActivity.state) ?? [:]
                    return Record(["id": .string(String(format: "dddddddd-dddd-4ddd-8ddd-%012d", number)), "sequence": .number(Double(number)), "user_id": .string(account), "task_id": .string("root"), "actor_id": .null,
                        "recorded_at": .string(TaskActivity.stamp(date)), "effective_at": .string(TaskActivity.stamp(date)), "completion_version": .number(0), "kinds": .array(TaskActivity.changes(before: b, after: a).map { .string($0.rawValue) }),
                        "before_state": .object(b), "after_state": .object(a), "root_context": TaskRootActivityContext.document(before: before, after: after)])
                }
                var rows = [event(1, nil, open, now.addingTimeInterval(-8 * 86400)), event(2, open, done, now.addingTimeInterval(-60)), event(3, done, open, now), event(4, done, moved, now.addingTimeInterval(-30)), event(5, moved, done, now.addingTimeInterval(1)), event(6, done, nil, now.addingTimeInterval(-7 * 86400))]
                switch variant % 6 {
                case 0: rows += [rows[1], rows[3]]
                case 1: rows[1]["root_context"] = .null
                case 2: var context = rows[1]["root_context"].object; context["after_type"] = .string("unknown"); rows[1]["root_context"] = .object(context)
                case 3: rows[1]["recorded_at"] = .string("invalid"); rows.append(Record(["id": .string("unsupported")]))
                case 4: var future = rows[1]; future["recorded_at"] = .string(TaskActivity.stamp(now.addingTimeInterval(1))); rows.insert(future, at: 0)
                default: var context = rows[1]["root_context"].object; context["version"] = .number(2); rows[1]["root_context"] = .object(context)
                }
                if variant % 2 == 1 { rows.reverse() }
                var projects = [project(), project(second, name: "Second")]
                if variant % 4 == 0 { projects.append(project(projectID.uppercased(), name: "Duplicate")) }
                let epoch = variant % 4 == 0 ? [] : [Record(["id": .string("current"), "recorded_from": .string(variant % 4 == 1 ? "2026-01-01T00:00:00Z" : variant % 4 == 2 ? TaskActivity.stamp(now.addingTimeInterval(1)) : "invalid")])]
                let value = WidgetProjection.pulsePayload(tasks: [open, done], projects: projects, activity: rows, epoch: epoch, account: account, readable: variant != 15, now: now, calendar: calendar)
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                digests.append(DueReminder.digest(String(decoding: try encoder.encode(value), as: UTF8.self)))
            }
        }
        let digest = DueReminder.digest(digests.joined(separator: "\n"))
        print("PULSE_HISTORY_CORPUS \(digests.count) \(digest)")
        XCTAssertEqual(digests.count, 64)
        XCTAssertEqual(digest, "8b8a1210f63dafb2d1a9d66b084d49068dad1fef3727b92e1daac8c07fecda12", "Frozen before sharing parsed widget history")
    }

    func testPreparedHistoryKeepsDailyReadingsAndRejectsDifferentProject() throws {
        let state = sample(), tasks = state.tables["tasks"] ?? []
        var rows = state.tables[TaskActivity.table] ?? []
        var unreadable = try XCTUnwrap(rows.first)
        unreadable["id"] = .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeee74")
        var context = unreadable["root_context"].object; context["after_type"] = .string("unknown")
        unreadable["root_context"] = .object(context)
        var future = try XCTUnwrap(rows.first); future["id"] = .string("ffffffff-ffff-4fff-8fff-ffffffffff75")
        future["recorded_at"] = .string(TaskActivity.stamp(now.addingTimeInterval(1)))
        rows += [rows[0], unreadable, future, Record(["id": .string("malformed")])]
        func compare(_ actual: ProjectPulseReading, _ expected: ProjectPulseReading) {
            XCTAssertEqual([actual.total, actual.completed, actual.completions, actual.reopens, actual.additions, actual.movedIn, actual.movedOut, actual.malformed], [expected.total, expected.completed, expected.completions, expected.reopens, expected.additions, expected.movedIn, expected.movedOut, expected.malformed])
            XCTAssertEqual(actual.events, expected.events); XCTAssertEqual(actual.timeline, expected.timeline)
            XCTAssertEqual(actual.start, expected.start); XCTAssertEqual(actual.end, expected.end)
            XCTAssertEqual(actual.historyIncomplete, expected.historyIncomplete); XCTAssertEqual(actual.countsIncomplete, expected.countsIncomplete)
        }
        for project in [projectID, projectID.uppercased(), "different"] {
            let history = ProjectPulseReading.History(project: project, activity: rows)
            for day in 0..<8 {
                let date = try XCTUnwrap(calendar.date(byAdding: .day, value: day, to: now))
                let original = ProjectPulseReading(project: project, tasks: tasks, activity: rows, now: date, calendar: calendar)
                compare(ProjectPulseReading(project: project, tasks: tasks, activity: [], now: date, calendar: calendar, history: history), original)
                compare(ProjectPulseReading(project: project, tasks: tasks, activity: rows, now: date, calendar: calendar, history: .init(project: "wrong project", parsed: [])), original)
            }
        }
    }

    func testActualAppProjectionMatchesCurrentScopeAndNativeEventCounts() throws {
        let s = sample(), snapshot = try widget(s), pulse = try XCTUnwrap(snapshot.projectPulse), p = try XCTUnwrap(pulse.projects.first), day = try XCTUnwrap(p.days["2026-10-06"])
        let native = ProjectPulseReading(project: projectID, tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now, calendar: calendar)
        XCTAssertEqual(p.total, native.total); XCTAssertEqual(p.completed, native.completed); XCTAssertEqual(day.completions, native.completions); XCTAssertEqual(day.reopens, native.reopens)
        XCTAssertEqual(p.completed, 1); XCTAssertEqual(day.completions, 2); XCTAssertEqual(day.reopens, 1); XCTAssertEqual(day.attention.map(\.id), ["attention"])
        XCTAssertEqual(snapshot.pulseStatus(p.id, at: now, calendar: calendar), .ready)
        XCTAssertEqual(ProjectPulseLink.parse(snapshot.pulseURL(p.id)), ProjectPulseLink(account: owner, project: projectID))
        XCTAssertEqual(p.days.count, 8)
    }
    func testTomorrowRollsSevenLocalDaysWithoutInventingUnreceivedActivityAcrossDST() throws {
        let at = TaskPlanning.instant("2026-03-29T10:00:00Z")!, start = TaskPlanning.instant("2026-03-23T08:00:00Z")!
        var s = Snapshot(tables: ["projects": [project()], "tasks": [task()]])
        let t = s.tables["tasks"]![0], c = Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: ["completed": .bool(true), "completed_at": .string(TaskActivity.stamp(start))])
        s.apply(c); TaskActivity.recordLocal(c, before: t, after: s.tables["tasks"]![0], snapshot: &s, account: owner, now: start)
        var future = s.tables[TaskActivity.table]![0]; future["id"] = .string(UUID().uuidString); future["sequence"] = .number(2); future["recorded_at"] = .string(TaskActivity.stamp(at.addingTimeInterval(1))); s.tables[TaskActivity.table]!.append(future)
        let pulse = try XCTUnwrap(widget(s, at: at).projectPulse), p = pulse.projects[0]
        XCTAssertEqual(p.days["2026-03-29"]?.completions, 1); XCTAssertEqual(p.days["2026-03-30"]?.completions, 0)
        XCTAssertEqual(p.completed, 1)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: at))!
        XCTAssertTrue(pulse.timelineDates(from: at, updated: at.timeIntervalSinceReferenceDate, calendar: calendar).contains(midnight))
    }
    func testNoEpochAndMalformedHistoryHaveExplicitStatesWithoutChangingCurrentCompletion() throws {
        var s = sample(); s.tables[TaskActivity.epochTable] = []
        var pulse = try XCTUnwrap(widget(s).projectPulse); XCTAssertEqual(pulse.history, "unavailable"); XCTAssertNil(pulse.recordedFrom); XCTAssertEqual(pulse.projects[0].completed, 1)
        s = sample(); s.tables[TaskActivity.table]![0]["sequence"] = .number(0.5)
        pulse = try XCTUnwrap(widget(s).projectPulse); XCTAssertEqual(pulse.history, "incomplete"); XCTAssertEqual(pulse.projects[0].completed, 1)
        XCTAssertNil(try widget(s, readable: false).projectPulse)
    }
    func testStrictProjectionBoundsVersionForeignOwnerDuplicateAndMalformedDays() throws {
        let good = try XCTUnwrap(widget(sample()).projectPulse); XCTAssertTrue(good.valid(for: owner))
        XCTAssertFalse(good.valid(for: other))
        var bad = good; bad.version = 99; XCTAssertFalse(bad.valid(for: owner))
        bad = good; bad.projects.append(bad.projects[0]); XCTAssertFalse(bad.valid(for: owner))
        bad = good; bad.projects[0].completed = bad.projects[0].total + 1; XCTAssertFalse(bad.valid(for: owner))
        bad = good; bad.recordedFrom = .infinity; XCTAssertFalse(bad.valid(for: owner))
        bad = good; bad.projects[0].days.removeValue(forKey: "2026-10-06"); XCTAssertFalse(bad.valid(for: owner))
        bad = good; bad.projects[0].days["2026-10-06"]!.attentionCount = -1; XCTAssertFalse(bad.valid(for: owner))
        bad = good; bad.projects[0].days["2026-10-06"]!.attention.append(bad.projects[0].days["2026-10-06"]!.attention[0]); XCTAssertFalse(bad.valid(for: owner))
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"updated":123,"tasks":[]}"#.utf8)); XCTAssertEqual(legacy.pulseStatus(nil, at: now), .refresh)
    }
    func testExactExpiryTimezoneAndMissingProjectKeepSelectedIdentity() throws {
        let w = try widget(sample()), p = w.projectPulse!.projects[0]
        XCTAssertEqual(w.pulseStatus(nil, at: now, calendar: calendar), .choose)
        let missing = PulseProject.key(account: owner, project: "removed")
        XCTAssertEqual(w.pulseStatus(missing, at: now, calendar: calendar), .unavailable)
        XCTAssertEqual(ProjectPulseLink.parse(w.pulseURL(missing))?.project, "removed")
        XCTAssertEqual(w.pulseStatus(p.id, at: now.addingTimeInterval(86_400), calendar: calendar), .refresh)
        XCTAssertEqual(w.pulseStatus(p.id, at: now.addingTimeInterval(-301), calendar: calendar), .refresh)
        var otherZone = calendar; otherZone.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(w.pulseStatus(p.id, at: now, calendar: otherZone), .refresh)
        let old = PulseProject.key(account: other, project: projectID)
        XCTAssertEqual(ProjectPulseLink.parse(w.pulseURL(old))?.account, other)
        XCTAssertEqual(w.pulseStatus(old, at: now, calendar: calendar), .unavailable)
        XCTAssertEqual(w.projectPulse!.timelineDates(from: now, updated: w.updated, calendar: calendar).last, now.addingTimeInterval(86_400))
    }
    func testUnicodeBoundsPrivateContentAndSignedOutProjection() throws {
        var s = sample(); s.tables["projects"]![0]["name"] = .string(String(repeating: "👩🏽‍💻café", count: 300)); s.tables["tasks"]![1]["title"] = .string(String(repeating: "👩🏽‍💻café", count: 300))
        let pulse = try XCTUnwrap(widget(s).projectPulse), p = pulse.projects[0]
        XCTAssertLessThanOrEqual(p.name.count, 160); XCTAssertLessThanOrEqual(p.name.utf8.count, 1000)
        XCTAssertLessThanOrEqual(p.days["2026-10-06"]!.attention[0].title.utf8.count, 800)
        let data = try JSONEncoder().encode(pulse), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE FULL NOTES")); XCTAssertFalse(text.contains("before_state")); XCTAssertFalse(text.contains("actor_id"))
        XCTAssertNil(try widget(s, account: "").projectPulse)
    }
    func testCatalogueBoundsAndRenameUseStableAccountProjectKeys() throws {
        var s = sample(); s.tables["projects"] = (0..<2049).map { project("p" + String(format: "%04d", $0), name: "Studio") }
        let w = try widget(s), pulse = try XCTUnwrap(w.projectPulse)
        XCTAssertEqual(pulse.projects.count, 2048); XCTAssertEqual(pulse.omitted, 1)
        XCTAssertEqual(w.pulseSubtitle(pulse.projects[0]), "Project · p0000")
        XCTAssertEqual(w.pulseStatus(PulseProject.key(account: owner, project: "p2048"), at: now, calendar: calendar), .refresh)
        s = sample(); let first = try widget(s).projectPulse!.projects[0]; s.tables["projects"]![0]["name"] = .string("Renamed")
        let renamed = try widget(s).projectPulse!.projects[0]; XCTAssertEqual(first.id, renamed.id); XCTAssertEqual(renamed.name, "Renamed")
    }
    func testStrictAccountBoundLinkAndSelectionEscapingRejectForgedURLs() {
        let link = ProjectPulseLink(account: "owner café?#%", project: "project/👩🏽‍💻?#%")
        XCTAssertEqual(ProjectPulseLink.parse(link.url), link); XCTAssertEqual(ProjectPulseLink.parse(ProjectPulseLink(account: owner).url), ProjectPulseLink(account: owner))
        XCTAssertEqual(PulseProject.link(for: PulseProject.key(account: link.account, project: link.project!)), link)
        for url in ["taskfold://pulse/?account=owner", "taskfold://pulse?account=owner&account=other", "taskfold://pulse?account=owner&project=", "taskfold://pulse?project=x", "taskfold://pulse?account=owner&extra=x", "taskfold://pulse?account=owner#fragment", "taskfold://user@pulse?account=owner", "taskfold://pulse:33?account=owner"] { XCTAssertNil(ProjectPulseLink.parse(URL(string: url)!)) }
        XCTAssertNil(PulseProject.link(for: "not-base64")); XCTAssertNil(ProjectPulseLink.parse(ProjectPulseLink(account: String(repeating: "x", count: 257)).url))
    }
}
