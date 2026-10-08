import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class WidgetListTests: XCTestCase {
    func testCreationProjectionUsesCivilDaysAndExpiresWithoutPublishingCreationMetadata() throws {
        var first = task("created-first"); first["created_at"] = .string("2026-10-23T22:00:00Z")
        var fold = task("created-fold"); fold["created_at"] = .string("2026-10-25T01:30:00Z")
        var unknown = task("unknown-creation"); unknown["created_at"] = .null
        let rows = [first, fold, unknown]
        for expression in ["created:today", "created before:today", "created after:-1 days"] {
            var parser = try FilterParser(expression, context: FilterContext()); let rule = try parser.parse()
            let data = try snapshot(rows, views: [view(rule, name: "Creation")]); let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
            for offset in 0...7 {
                let instant = try XCTUnwrap(cph.date(byAdding: .day, value: offset, to: now))
                let day = WidgetSnapshot.day(instant, calendar: cph)
                let expected: Set<String>
                switch expression {
                case "created:today": expected = offset == 0 ? [first.id] : offset == 1 ? [fold.id] : []
                case "created before:today": expected = offset == 0 ? [] : offset == 1 ? [first.id] : [first.id, fold.id]
                default: expected = offset == 0 ? [first.id, fold.id] : offset == 1 ? [fold.id] : []
                }
                XCTAssertEqual(Set(data.listTasks(key, at: instant, calendar: cph).map(\.id)), expected, "\(expression), \(day)")
            }
            XCTAssertEqual(data.listStatus(key, at: cph.date(byAdding: .day, value: 8, to: now)!, calendar: cph), .refresh)
            let encoded = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
            XCTAssertFalse(encoded.contains("created_at")); XCTAssertFalse(encoded.contains("created_on")); XCTAssertFalse(encoded.contains("2026-10-23T22"))
        }
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
    private var cph: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    private let project = Record(["id": .string("studio"), "name": .string("Studio")])
    private let label = Record(["id": .string("waiting"), "name": .string("Waiting")])
    private func task(_ id: String, due: String = "", projectID: String = "studio", labels: [String] = [], done: Bool = false, minutes: Int? = nil) -> Record {
        var task = Record.task(user: "owner", project: projectID)
        task["id"] = .string(id); task["title"] = .string(id); task["due_date"] = due.isEmpty ? .null : .string(due)
        task["labels"] = .array(labels.map(JSON.string)); task["completed"] = .bool(done)
        task["duration_minutes"] = minutes.map { .number(Double($0)) } ?? .null; return task
    }
    private func snapshot(_ tasks: [Record], account: String = "owner", projects: [Record]? = nil, labels: [Record]? = nil, views: [Record] = []) throws -> WidgetSnapshot {
        let payload = WidgetProjection.payload(tasks: tasks, projects: projects ?? [project], account: account, now: now, labels: labels ?? [label], savedViews: views, calendar: cph)
        return try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
    }
    private func view(_ rule: FilterRule, name: String = "Today") -> Record { Record(["id": .string("filter"), "name": .string(name), "query_ast": rule.document]) }

    func testRelativePlanAndDeadlineFallbackProjectionChangesAtCivilMidnightAcrossDST() throws {
        var deadline = task("deadline"); deadline["deadline_date"] = .string("2026-10-25")
        var both = task("both", due: "2026-10-26"); both["deadline_date"] = .string("2026-10-25")
        let rows = [task("plan", due: "2026-10-25"), deadline, both, task("none")]
        for expression in ["date:tomorrow", "effective-due:tomorrow", "deadline after:today"] {
            var parser = try FilterParser(expression, context: FilterContext()); let rule = try parser.parse()
            let data = try snapshot(rows, views: [view(rule)])
            let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
            for offset in 0...7 {
                let instant = try XCTUnwrap(cph.date(byAdding: .day, value: offset, to: now))
                let expected = rows.filter { rule.matches($0, today: WidgetSnapshot.day(instant, calendar: cph), userID: "owner", labels: [], timeZone: cph.timeZone.identifier) }.map(\.id)
                XCTAssertEqual(Set(data.listTasks(key, at: instant, calendar: cph).map(\.id)), Set(expected), expression)
            }
            XCTAssertEqual(data.listStatus(key, at: cph.date(byAdding: .day, value: 8, to: now)!, calendar: cph), .refresh)
            let encoded = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
            XCTAssertFalse(encoded.contains("query_ast")); XCTAssertFalse(encoded.contains("effective_due_on"))
            if expression == "effective-due:tomorrow" { XCTAssertEqual(Set(data.listTasks(key, at: now, calendar: cph).map(\.id)), ["plan", "deadline"]) }
        }
    }

    func testRenameKeepsIdentityAndAccountSwitchCannotReuseSelectedList() throws {
        let first = try snapshot([task("a")]); let key = try XCTUnwrap(first.availableLists.first { $0.kind == "project" }?.id)
        var renamed = project; renamed["name"] = .string("New Studio")
        let second = try snapshot([task("a")], projects: [renamed])
        XCTAssertEqual(second.list(key)?.name, "New Studio"); XCTAssertEqual(second.listTasks(key, at: now).map(\.id), ["a"])
        let other = try snapshot([task("a")], account: "another")
        XCTAssertNil(other.list(key)); XCTAssertEqual(other.listStatus(key, at: now), .unavailable); XCTAssertTrue(other.listTasks(key, at: now).isEmpty)
    }
    func testProjectsLabelsAndCompletedWorkUseTheNativeMembershipContract() throws {
        let rows = [task("id", labels: ["waiting"]), task("legacy", labels: ["Waiting"]), task("foreign", projectID: "other"), task("done", labels: ["waiting"], done: true)]
        let data = try snapshot(rows)
        let projectKey = try XCTUnwrap(data.availableLists.first { $0.kind == "project" }?.id)
        let labelKey = try XCTUnwrap(data.availableLists.first { $0.kind == "label" }?.id)
        XCTAssertEqual(Set(data.listTasks(projectKey, at: now).map(\.id)), ["id", "legacy"])
        XCTAssertEqual(Set(data.listTasks(labelKey, at: now).map(\.id)), ["id", "legacy"])
        XCTAssertFalse(data.tasks.contains { $0.id == "done" })
        let deleted = try snapshot(rows, projects: [], labels: [])
        XCTAssertEqual(deleted.listStatus(projectKey, at: now), .unavailable); XCTAssertEqual(deleted.listStatus(labelKey, at: now), .unavailable)
    }
    func testSavedFilterUsesNativeEvaluatorAtEachLocalMidnightAcrossDST() throws {
        let rows = [task("today", due: "2026-10-24"), task("next", due: "2026-10-25"), task("later", due: "2026-10-26"), task("undated")]
        let rule = FilterRule.or([.predicate("today", ""), .predicate("no_date", "")])
        let data = try snapshot(rows, views: [view(rule)])
        let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
        for date in WidgetSnapshot.timelineDates(from: now, calendar: cph) {
            let expected = rows.filter { rule.matches($0, today: WidgetSnapshot.day(date, calendar: cph), userID: "owner", labels: [], timeZone: cph.timeZone.identifier) }.map(\.id)
            XCTAssertEqual(Set(data.listTasks(key, at: date, calendar: cph).map(\.id)), Set(expected))
        }
        let target = try XCTUnwrap(data.list(key)); XCTAssertEqual(target.days.count, 8)
        XCTAssertTrue(target.days.keys.contains("2026-10-31"))
    }
    func testExpiredFilterAndTravelAskForRefreshInsteadOfReportingZeroTasks() throws {
        let data = try snapshot([task("a")], views: [view(.predicate("no_date", ""))])
        let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
        let expired = cph.date(byAdding: .day, value: 8, to: now)!
        XCTAssertEqual(data.listStatus(key, at: expired, calendar: cph), .refresh)
        var ny = cph; ny.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(data.listStatus(key, at: now, calendar: ny), .refresh)
        XCTAssertTrue(data.listTasks(key, at: now, calendar: ny).isEmpty)
        let projectKey = try XCTUnwrap(data.availableLists.first { $0.kind == "project" }?.id)
        XCTAssertEqual(data.listStatus(projectKey, at: expired, calendar: ny), .ready)
    }
    func testInvalidOrDeletedReferencesUnderNegationCannotBecomeAllTasks() throws {
        let data = try snapshot([task("a")], views: [view(.not(.predicate("project", "deleted")))])
        let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
        XCTAssertEqual(data.listStatus(key, at: now, calendar: cph), .unavailable)
        XCTAssertTrue(data.listTasks(key, at: now, calendar: cph).isEmpty)
    }
    func testSignedOutSnapshotClearsListsAndLegacySnapshotsOfferNoFalseFallback() throws {
        let data = try snapshot([task("secret", labels: ["waiting"])], account: "", views: [view(.predicate("all", ""))])
        XCTAssertTrue(data.availableLists.isEmpty); XCTAssertTrue(data.tasks.isEmpty); XCTAssertEqual(data.updated, 0)
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"version":2,"updated":1,"account":"owner","tasks":[]}"#.utf8))
        XCTAssertTrue(legacy.availableLists.isEmpty); XCTAssertEqual(legacy.listStatus("old-selection", at: now), .unavailable)
        XCTAssertEqual(legacy.listStatus(nil, at: now), .choose)
    }
    func testIndependentSelectedListsNarrowWindowAndDeadlineResultsWithoutChangingSnapshot() throws {
        var small = task("small", labels: ["waiting"], minutes: 10); small["deadline_date"] = .string("2026-10-25")
        let data = try snapshot([small, task("large", minutes: 45), task("unknown", labels: ["waiting"]), task("elsewhere", projectID: "other", minutes: 5)])
        let labelKey = try XCTUnwrap(data.availableLists.first { $0.kind == "label" }?.id)
        let projectKey = try XCTUnwrap(data.availableLists.first { $0.kind == "project" }?.id)
        let labelScope = data.scoped(to: labelKey, at: now, calendar: cph)
        XCTAssertEqual(labelScope.smallWindow(minutes: 10, at: now, calendar: cph).map(\.id), ["small"])
        XCTAssertEqual(labelScope.windowTasks(scope: .all, at: now).filter { $0.estimate == nil }.count, 1)
        XCTAssertEqual(labelScope.deadlines(at: now, calendar: cph).map(\.id), ["small"])
        XCTAssertEqual(Set(data.scoped(to: projectKey, at: now).smallWindow(minutes: 45, at: now).map(\.id)), ["small", "large"])
        XCTAssertEqual(data.tasks.count, 4)
    }
    func testMembershipDeduplicatesSkipsMissingRowsAndRejectsUnownedListKeys() throws {
        var data = try snapshot([task("a")])
        let index = try XCTUnwrap(data.lists.firstIndex { $0.kind == "project" })
        let key = data.lists[index].id; data.lists[index].days["*"] = ["a", "missing", "a"]
        XCTAssertEqual(data.listTasks(key, at: now).map(\.id), ["a"])
        data.lists[index].recordID = "other"
        XCTAssertNil(data.list(key)); XCTAssertTrue(data.listTasks(key, at: now).isEmpty)
    }
    func testPayloadExposesOnlyListDisplayMetadataAndOpenIDsAndScopeLinksEscapeIDs() throws {
        let data = try snapshot([task("a")], views: [view(.predicate("all", ""))])
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(data), encoding: .utf8))
        XCTAssertFalse(encoded.contains("query_ast")); XCTAssertFalse(encoded.contains("reminder_specs")); XCTAssertFalse(encoded.contains("\"pending\"")); XCTAssertFalse(encoded.contains("description"))
        let link = WidgetLinks.scoped("label", id: "with /?#% spaces")
        XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/with%20%2F%3F%23%25%20spaces")
        XCTAssertNil(link.query); XCTAssertNil(link.fragment)
    }
    func testSameNamesAndCrossKindIDsRemainDistinctAndOnlyDuplicatesNeedDisambiguation() throws {
        var other = project; other["id"] = .string("other-studio")
        var sameIDLabel = label; sameIDLabel["id"] = .string(project.id); sameIDLabel["name"] = .string(project.name)
        let data = try snapshot([task("a")], projects: [project, other], labels: [sameIDLabel])
        XCTAssertEqual(Set(data.availableLists.map(\.id)).count, 3)
        let projects = data.availableLists.filter { $0.kind == "project" }
        XCTAssertNotEqual(data.listSubtitle(projects[0]), data.listSubtitle(projects[1]))
        let label = try XCTUnwrap(data.availableLists.first { $0.kind == "label" })
        XCTAssertEqual(data.listSubtitle(label), "Label")
    }


    func testKeywordTimeLabelsAndRecurringFiltersUsePrivateNativeProjection() throws {
        var selected = task("Send email"); selected["description"] = .string("Café agenda"); selected["is_recurring"] = .bool(true)
        var timed = selected; timed["id"] = .string("timed"); timed["due_time"] = .string("09:00")
        var labelled = selected; labelled["id"] = .string("labelled"); labelled["labels"] = .array([.string("Waiting")])
        var plain = selected; plain["id"] = .string("plain"); plain["is_recurring"] = .bool(false)
        var parser = try FilterParser("search: café email & no time & no labels & recurring", context: FilterContext())
        let rule = try parser.parse(); let data = try snapshot([selected, timed, labelled, plain], views: [view(rule)])
        let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
        XCTAssertEqual(data.listTasks(key, at: now, calendar: cph).map(\.id), [selected.id])
        let encoded = String(data: try JSONEncoder().encode(data), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("Café agenda")); XCTAssertFalse(encoded.contains("query_ast")); XCTAssertFalse(encoded.contains("recurrence_pattern"))
    }
    func testChangedSearchDescriptionAndAccountInvalidateWidgetMembership() throws {
        var row = task("Draft"); row["description"] = .string("Send email")
        let rule = FilterRule.predicate("search", "email")
        let first = try snapshot([row], views: [view(rule)]); let key = try XCTUnwrap(first.availableLists.first { $0.kind == "filter" }?.id)
        XCTAssertEqual(first.listTasks(key, at: now).map(\.id), [row.id])
        row["description"] = .string("Call the studio")
        let changed = try snapshot([row], views: [view(rule)]); XCTAssertTrue(changed.listTasks(key, at: now).isEmpty)
        let other = try snapshot([row], account: "another", views: [view(rule)]); XCTAssertNil(other.list(key)); XCTAssertTrue(other.listTasks(key, at: now).isEmpty)
    }
    func testTimedSavedFiltersProjectExactNativeMembershipAcrossDSTAndRelativeDays() throws {
        var morning = task("morning", due: "2026-10-25"); morning["due_time"] = .string("01:30:00"); morning["time_zone"] = .string("Europe/Copenhagen")
        var fold = task("fold", due: "2026-10-25"); fold["due_time"] = .string("02:30"); fold["time_zone"] = .string("Europe/Copenhagen"); fold["scheduled_at"] = .string("2026-10-25T01:30:00Z")
        let rows = [morning, fold, task("untimed", due: "2026-10-25")]
        for expression in ["date before:tomorrow at 02:30", "time before:02:30", "date:tomorrow & time:02:30"] {
            var parser = try FilterParser(expression, context: FilterContext()); let rule = try parser.parse()
            let data = try snapshot(rows, views: [view(rule)])
            let key = try XCTUnwrap(data.availableLists.first { $0.kind == "filter" }?.id)
            for offset in 0...7 {
                let date = try XCTUnwrap(cph.date(byAdding: .day, value: offset, to: now))
                let expected = rows.filter { rule.matches($0, today: WidgetSnapshot.day(date, calendar: cph), userID: "owner", labels: [], timeZone: cph.timeZone.identifier) }.map(\.id)
                XCTAssertEqual(Set(data.listTasks(key, at: date, calendar: cph).map(\.id)), Set(expected))
            }
            if expression == "date before:tomorrow at 02:30" { XCTAssertEqual(data.listTasks(key, at: now, calendar: cph).map(\.id), ["morning"]) }
            let encoded = String(decoding: try JSONEncoder().encode(data), as: UTF8.self); XCTAssertFalse(encoded.contains("query_ast")); XCTAssertFalse(encoded.contains("planned_time_before"))
        }
    }

}


extension WidgetListTests {
    func testElapsedListMembershipExpiryTimelineAndPrivatePayload() throws {
        var inside = task("inside", due: "2026-10-24"); inside["due_time"] = .string("15:00")
        var edge = task("edge", due: "2026-10-24"); edge["due_time"] = .string("18:00")
        var parser = try FilterParser("date before:+4 hours", context: FilterContext()); let rule = try parser.parse()
        let value = try snapshot([inside, edge, task("no-clock", due: "2026-10-24")], views: [view(rule)])
        let target = try XCTUnwrap(value.availableLists.first { $0.kind == "filter" })
        XCTAssertEqual(target.days.count, 1)
        XCTAssertEqual(value.listStatus(target.id, at: now, calendar: cph), .ready)
        XCTAssertEqual(value.listTasks(target.id, at: now, calendar: cph).map(\.id), ["inside"])
        XCTAssertEqual(value.listStatus(target.id, at: now.addingTimeInterval(59), calendar: cph), .ready)
        for offset in [-1.0, 60, 86400] {
            XCTAssertEqual(value.listStatus(target.id, at: now.addingTimeInterval(offset), calendar: cph), .refresh)
            XCTAssertEqual(value.listTasks(target.id, at: now.addingTimeInterval(offset), calendar: cph).map(\.id), [])
        }
        XCTAssertTrue(value.listTimelineDates(target.id, from: now, calendar: cph).contains(now.addingTimeInterval(60)))
        XCTAssertEqual(value.listTimelineDates(target.id, from: now, calendar: cph).count, 9)
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("query_ast")); XCTAssertFalse(encoded.contains("+4 hours")); XCTAssertFalse(encoded.contains("planned_before"))
    }
    func testElapsedListRejectsMalformedWindowsAndLegacyListsKeepDailyProjection() throws {
        var parser = try FilterParser("date before:+4 hours", context: FilterContext()); let rule = try parser.parse()
        var value = try snapshot([], views: [view(rule)])
        let index = try XCTUnwrap(value.lists.firstIndex { $0.kind == "filter" }); let id = value.lists[index].id
        for (start, end) in [(Optional<Double>.none, now.timeIntervalSinceReferenceDate + 60), (now.timeIntervalSinceReferenceDate, nil), (now.timeIntervalSinceReferenceDate, now.timeIntervalSinceReferenceDate + 61), (.nan, .infinity)] {
            value.lists[index].clockUpdated = start; value.lists[index].clockValidUntil = end
            XCTAssertEqual(value.listStatus(id, at: now, calendar: cph), .refresh)
        }
        let daily = try snapshot([], views: [view(.predicate("planned_on", "today"))])
        let target = try XCTUnwrap(daily.availableLists.first { $0.kind == "filter" })
        XCTAssertNil(target.clockUpdated); XCTAssertNil(target.clockValidUntil); XCTAssertEqual(target.days.count, 8)
        XCTAssertEqual(daily.listStatus(target.id, at: now.addingTimeInterval(61), calendar: cph), .ready)
        XCTAssertEqual(daily.listTimelineDates(target.id, from: now, calendar: cph), WidgetSnapshot.timelineDates(from: now, calendar: cph))
    }
}
