import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class WidgetListTests: XCTestCase {
    func testIndexedProjectAndLabelCandidatesKeepAliasesOrderingAndSourceUpdates() {
        var a = task("a", projectID: "A", labels: ["label-id", "label-id"])
        var b = task("b", projectID: "A", labels: ["Alias"])
        var c = task("c", projectID: "B", labels: ["Alias", "label-id"])
        var d = task("d", projectID: "B", labels: ["alias"])
        a["priority"] = .number(4); b["priority"] = .number(1); c["priority"] = .number(2); d["priority"] = .number(3)
        a["title"] = .string("AA"); b["title"] = .string("ZZ"); c["title"] = .string("MM")
        let cache = TaskCache(); cache.update([a, b, c, d])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .project("A"), sort: "manual")).map(\.id), ["b", "a"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .project("B"), sort: "priority")).map(\.id), ["c", "d"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .label("label-id"), sort: "manual", labelName: "Alias")).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .label("label-id"), sort: "title", labelName: "Alias")).map(\.id), ["a", "c", "b"])
        b["project_id"] = .string("B"); b["labels"] = .array([])
        d["labels"] = .array([.string(""), .object(["name": .string("Alias")])])
        cache.update([a, b, c, d])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .project("A"), sort: "manual")).map(\.id), ["a"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .project("B"), sort: "priority")).map(\.id), ["b", "c", "d"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .label("label-id"), sort: "manual", labelName: "Alias")).map(\.id), ["c", "a"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .label("label-id"), sort: "manual")).map(\.id), ["c", "d", "a"], "Legacy empty-string membership remains exact; objects do not become label names")
    }
    func testFullStructuredWorkflowPublishesAllWidgetListsGroupsAndMembership() throws {
        let count = 5000, account = "11111111-1111-4111-8111-111111111111"
        let document: JSON = .object(["version": .number(1), "kind": .string("project"),
            "projects": .array([.object(["id": .string("root"), "name": .string("Full workflow")])]),
            "sections": .array((0..<count).map { .object(["id": .string("s\($0)"), "name": .string("Section \($0)"), "project_id": .string("root"), "order_index": .number(Double($0))]) }),
            "tasks": .array((0..<count).map { .object(["id": .string("t\($0)"), "title": .string("Task \($0)"), "project_id": .string("root"), "section_id": .string("s\($0)"), "labels": .array([.object(["name": .string("Label \($0)")])]), "subtasks": .array([])]) })])
        let changes = try WorkflowTemplate(document: document).instantiate(account: account, name: "Full workflow")
        let tables = Dictionary(grouping: changes, by: \.table).mapValues { $0.map { Record($0.fields) } }
        let tasks = try XCTUnwrap(tables["tasks"])
        let payload = WidgetProjection.payload(tasks: tasks, projects: tables["projects"]!, account: account, now: now, labels: tables["labels"]!, sections: tables["sections"]!, calendar: cph, viewOrders: tables["view_orders"]!)
        let data = try JSONEncoder().encode(JSON.object(payload)), snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(snapshot.tasks.count, count); XCTAssertEqual(snapshot.lists.count, count + 1)
        let projectList = try XCTUnwrap(snapshot.lists.first { $0.kind == "project" })
        XCTAssertEqual(projectList.days["*"], tasks.map(\.id))
        XCTAssertEqual(projectList.groups?["*"]?.count, count)
        XCTAssertEqual(projectList.groups?["*"]?.map(\.id), OrganizationOrder.sorted(tables["sections"]!).map(\.id))
        let expected = Dictionary(uniqueKeysWithValues: tasks.map { ($0["labels"].list[0].text, $0.id) })
        for label in snapshot.lists where label.kind == "label" { XCTAssertEqual(label.days["*"], expected[label.recordID].map { [$0] }) }
        XCTAssertEqual(snapshot.listStatus(projectList.id, at: now, calendar: cph), .ready)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = WidgetActionDisk(directory: root); try disk.publish(data)
        XCTAssertEqual(try disk.read().data, data)
    }

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

    func testCompletionTimelineExpiresLastTaskMessageWithoutDroppingListTransitions() throws {
        var value = try snapshot([])
        let key = try XCTUnwrap(value.availableLists.first { $0.kind == "project" }?.id)
        value.completionFeedback = WidgetCompletionFeedback(account: value.account, taskID: "last-task", title: "Completed proof", listIDs: [key], savedAt: now)
        let feedback = try XCTUnwrap(value.completionFeedback)
        let dates = value.completionTimelineDates(key, from: now, calendar: cph)
        XCTAssertEqual(dates, (value.listTimelineDates(key, from: now, calendar: cph) + [feedback.expiresAt]).sorted())
        XCTAssertTrue(feedback.visible(account: value.account, listID: key, at: now.addingTimeInterval(7.999)))
        XCTAssertFalse(feedback.visible(account: value.account, listID: key, at: feedback.expiresAt))
        XCTAssertFalse(value.completionTimelineDates(key, from: now.addingTimeInterval(9), calendar: cph).contains(feedback.expiresAt))
    }

    func testCompletionTimelineDoesNotScheduleOtherListOrAccountFeedback() throws {
        var value = try snapshot([])
        let key = try XCTUnwrap(value.availableLists.first { $0.kind == "project" }?.id)
        for (account, listIDs) in [("another", [key]), (value.account, ["another-list"])] {
            value.completionFeedback = WidgetCompletionFeedback(account: account, taskID: "task", title: "Private proof", listIDs: listIDs, savedAt: now)
            XCTAssertEqual(value.completionTimelineDates(key, from: now, calendar: cph), value.listTimelineDates(key, from: now, calendar: cph))
        }
        value.completionFeedback = WidgetCompletionFeedback(account: value.account, taskID: "task", title: "Future proof", listIDs: [key], savedAt: now.addingTimeInterval(10))
        XCTAssertEqual(value.completionTimelineDates(key, from: now, calendar: cph), value.listTimelineDates(key, from: now, calendar: cph))
        XCTAssertEqual(value.completionTimelineDates(nil, from: now, calendar: cph), value.listTimelineDates(nil, from: now, calendar: cph))
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


extension WidgetListTests {
    func testDatePreferenceWidgetProjectionsMatchNativeWithoutExportingPreferences() throws {
        var parser=try FilterParser("date:next week",context:FilterContext()); let rule=try parser.parse()
        let rows=[task("monday",due:"2026-10-26"),task("sunday",due:"2026-10-25")]
        let payload=WidgetProjection.payload(tasks:rows,projects:[],account:"owner",now:now,savedViews:[view(rule)],calendar:cph,datePreferences:DatePhrasePreferences(nextWeek:1,weekend:6))
        let data=try JSONEncoder().encode(JSON.object(payload)); let value=try JSONDecoder().decode(WidgetSnapshot.self,from:data)
        let target=try XCTUnwrap(value.availableLists.first { $0.kind=="filter" })
        XCTAssertEqual(value.listTasks(target.id,at:now,calendar:cph).map(\.id),["sunday"])
        XCTAssertEqual(target.days.count,8); XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("date_preferences"))
    }
}


extension WidgetListTests {
    func testFutureSettingsCannotBroadenSavedWidgetSelection() throws {
        let query: JSON = .object(["version": .number(1), "root": .object([
            "op": .string("predicate"), "field": .string("search"), "value": .string("email"), "case_sensitive": .bool(true)
        ])])
        let future = Record(["id": .string("future"), "name": .string("Future filter"), "query_ast": query])
        let value = try snapshot([task("Email"), task("email")], views: [future])
        let key = try XCTUnwrap(value.availableLists.first { $0.kind == "filter" }?.id)
        XCTAssertEqual(value.listStatus(key, at: now, calendar: cph), .unavailable)
        XCTAssertTrue(value.listTasks(key, at: now, calendar: cph).isEmpty)
        XCTAssertEqual(future["query_ast"], query)
    }
}


extension WidgetListTests {
    func testConfiguredListLinksRetainTheirWorkspaceWhenRecordIDsAreReused() throws {
        for owner in ["owner-a", "owner-b"] {
            let data = try snapshot([task("shared-task")], account: owner, views: [view(.predicate("all", ""))])
            XCTAssertEqual(Set(data.availableLists.map(\.kind)), ["project", "label", "filter"])
            for list in data.availableLists {
                let parts = try XCTUnwrap(URLComponents(url: list.url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "account", value: owner)])
                XCTAssertEqual(parts.url?.lastPathComponent, list.recordID)
            }
        }
    }
}

extension WidgetListTests {
    private func orderedSnapshot(_ tasks:[Record], sections:[Record]=[], views:[Record]=[], settings:[Record]=[], orders:[Record]=[]) throws -> WidgetSnapshot {
        try JSONDecoder().decode(WidgetSnapshot.self,from:JSONEncoder().encode(WidgetProjection.payload(tasks:tasks,projects:[project],account:"owner",now:now,labels:[label],sections:sections,savedViews:views,calendar:cph,viewPreferences:settings,viewOrders:orders)))
    }
    private func order(_ key:String,_ ids:[String],owner:String="owner") -> Record { Record(["id":.string(key),"user_id":.string(owner),"ids":.array(ids.map(JSON.string))]) }
    private func sortSetting(_ scope:String,_ sort:String,owner:String="owner") -> Record { Record(["id":.string(scope),"user_id":.string(owner),"sort_by":.string(sort)]) }
    func testProjectWidgetKeepsSectionOrderPriorityBandsAndNewTasksAfterSavedOrder() throws {
        let sections=[Record(["id":.string("drafts"),"project_id":.string("studio"),"name":.string("Drafts"),"order_index":.number(1)]),Record(["id":.string("review"),"project_id":.string("studio"),"name":.string("Review"),"order_index":.number(0)])]
        var high=task("high"), b=task("b"), c=task("c"), added=task("new"), draft=task("draft")
        high["priority"] = .number(1)
        for id in ["high","b","c","new"] {
            if id==high.id { high["section_id"] = .string("review") }; if id==b.id { b["section_id"] = .string("review") };if id==c.id { c["section_id"] = .string("review") };if id==added.id { added["section_id"] = .string("review") }
        }
        draft["section_id"] = .string("drafts")
        let orders=[order("group:studio:review",["c","b","high"])]
        let data=try orderedSnapshot([draft,b,c,high,added,task("loose")],sections:sections,orders:orders)
        let key=try XCTUnwrap(data.availableLists.first{$0.kind=="project"}?.id)
        XCTAssertEqual(data.listTasks(key,at:now,calendar:cph).map(\.id),["loose","high","c","b","new","draft"])
        XCTAssertEqual(data.listGroups(key,at:now,calendar:cph).map(\.name),["Tasks","Review","Drafts"])
        XCTAssertEqual(data.listGroups(key,at:now,calendar:cph).map(\.ids),[["loose"],["high","c","b","new"],["draft"]])
        let remaining=try orderedSnapshot([draft,b,added,task("loose")],sections:sections,orders:orders)
        XCTAssertEqual(remaining.listTasks(key,at:now,calendar:cph).map(\.id),["loose","b","new","draft"])
        XCTAssertEqual(remaining.listGroups(key,at:now,calendar:cph).map(\.name),["Tasks","Review","Drafts"])
    }
    func testLabelWidgetFollowsManualOrderAndExplicitSortWithoutForeignSettings() throws {
        let rows=[task("alpha",labels:["waiting"]),task("bravo",labels:["Waiting"]),task("charlie",labels:["waiting"])]
        let orders=[order("scope:label:waiting",["charlie","bravo","alpha"])]
        let manual=try orderedSnapshot(rows,orders:orders), key=try XCTUnwrap(manual.availableLists.first{$0.kind=="label"}?.id)
        XCTAssertEqual(manual.listTasks(key,at:now,calendar:cph).map(\.id),["charlie","bravo","alpha"])
        let title=try orderedSnapshot(rows,settings:[sortSetting("label:waiting","title")],orders:orders)
        XCTAssertEqual(title.listTasks(key,at:now,calendar:cph).map(\.id),["alpha","bravo","charlie"])
        let foreign=try orderedSnapshot(rows,settings:[sortSetting("label:waiting","title",owner:"another")],orders:orders+[order("scope:label:waiting",["alpha","bravo","charlie"],owner:"another")])
        XCTAssertEqual(foreign.listTasks(key,at:now,calendar:cph).map(\.id),["charlie","bravo","alpha"])
        XCTAssertEqual(manual.listGroups(key,at:now,calendar:cph).first?.name,"")
    }
    func testGroupedQueryWidgetUsesPerGroupOrderAndUniqueFirstMembership() throws {
        let rule=FilterRule.sections([.predicate("priority","1"),.predicate("all","")])
        var saved=view(rule);saved["grouping"] = .string("priority");saved["sort_by"] = .string("manual")
        var high=task("high");high["priority"] = .number(1)
        let orders=[order("scope:view:filter:group:"+rule.querySectionKeys[1]+":priority:4",["b","a"])]
        let data=try orderedSnapshot([task("a"),high,task("b"),task("done",done:true)],views:[saved],orders:orders)
        let key=try XCTUnwrap(data.availableLists.first{$0.kind=="filter"}?.id)
        XCTAssertEqual(data.listTasks(key,at:now,calendar:cph).map(\.id),["high","b","a"])
        let groups=data.listGroups(key,at:now,calendar:cph)
        XCTAssertEqual(groups.map(\.name),["Query 1 · Priority 1","Query 2 · No priority"])
        XCTAssertEqual(groups.map(\.ids),[["high"],["b","a"]])
        let remaining=try orderedSnapshot([task("a"),task("b")],views:[saved],orders:orders)
        XCTAssertEqual(remaining.listGroups(key,at:now,calendar:cph).map(\.name),["Query 2 · No priority"])
        let encoded=String(decoding:try JSONEncoder().encode(data),as:UTF8.self)
        XCTAssertFalse(encoded.contains("query_ast"));XCTAssertFalse(encoded.contains("sort_by"));XCTAssertFalse(encoded.contains("view_orders"))
    }
    func testWidgetGroupsFollowDayAndAccountValidityWithoutAddingOrDuplicatingTasks() throws {
        var saved=view(.predicate("planned_on","tomorrow"));saved["grouping"] = .string("priority")
        var data=try orderedSnapshot([task("tomorrow",due:"2026-10-25"),task("later",due:"2026-10-26")],views:[saved])
        let key=try XCTUnwrap(data.availableLists.first{$0.kind=="filter"}?.id)
        XCTAssertEqual(data.listGroups(key,at:now,calendar:cph).flatMap(\.ids),["tomorrow"])
        let next=try XCTUnwrap(cph.date(byAdding:.day,value:1,to:now))
        XCTAssertEqual(data.listGroups(key,at:next,calendar:cph).flatMap(\.ids),["later"])
        let expired=try XCTUnwrap(cph.date(byAdding:.day,value:8,to:now))
        XCTAssertTrue(data.listGroups(key,at:expired,calendar:cph).isEmpty)
        let index=try XCTUnwrap(data.lists.firstIndex{$0.id==key})
        data.lists[index].groups=[WidgetSnapshot.day(now,calendar:cph):[WidgetListGroup(id:"one",name:"First",ids:["tomorrow","later","tomorrow"]),WidgetListGroup(id:"two",name:"Second",ids:["tomorrow"])]]
        XCTAssertEqual(data.listGroups(key,at:now,calendar:cph).map(\.ids),[["tomorrow"]])
        data.account="another";XCTAssertTrue(data.listGroups(key,at:now,calendar:cph).isEmpty)
    }
    func testLegacyWidgetListsKeepOrderWithoutGroupMetadata() throws {
        let source=try orderedSnapshot([task("a"),task("b")],orders:[order("group:studio:none",["b","a"])])
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any])
        object["lists"]=(object["lists"] as? [[String:Any]])?.map{ row in var row=row;row.removeValue(forKey:"groups");return row }
        let decoded=try JSONDecoder().decode(WidgetSnapshot.self,from:JSONSerialization.data(withJSONObject:object))
        let key=try XCTUnwrap(decoded.availableLists.first{$0.kind=="project"}?.id)
        XCTAssertEqual(decoded.listGroups(key,at:now,calendar:cph).map(\.ids),[["b","a"]])
        XCTAssertEqual(decoded.listGroups(key,at:now,calendar:cph).map(\.name),[""])
    }
}


extension WidgetListTests {
    func testUnknownWidgetSortAndGroupingRequireRefreshInsteadOfInventingAnOrder() throws {
        var saved=view(.predicate("all",""));saved["sort_by"] = .string("future-sort")
        let sorted=try orderedSnapshot([task("a")],views:[saved],settings:[sortSetting("project:studio","future-sort")])
        for list in sorted.availableLists where list.kind != "label" {
            XCTAssertEqual(sorted.listStatus(list.id,at:now,calendar:cph),.unavailable)
            XCTAssertTrue(sorted.listTasks(list.id,at:now,calendar:cph).isEmpty)
            XCTAssertTrue(sorted.listGroups(list.id,at:now,calendar:cph).isEmpty)
        }
        saved["sort_by"] = .string("manual");saved["grouping"] = .string("future-group")
        let grouped=try orderedSnapshot([task("a")],views:[saved])
        let key=try XCTUnwrap(grouped.availableLists.first{$0.kind=="filter"}?.id)
        XCTAssertEqual(grouped.listStatus(key,at:now,calendar:cph),.unavailable)
        XCTAssertTrue(grouped.listGroups(key,at:now,calendar:cph).isEmpty)
    }
}
