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
