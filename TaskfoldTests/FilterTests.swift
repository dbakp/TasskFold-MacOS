import XCTest
@testable import TaskfoldCore

final class FilterTests: XCTestCase {
    func testDayWindowsParseRoundTripAndKeepExactOffsetsSeparate() throws {
        for (input, expected) in [("3 days", "planned_next_days"), ("-3 days", "planned_past_days"), ("date:3 days", "planned_next_days"), ("date:-3 days", "planned_past_days"), ("effective-due:3 days", "effective_due_next_days"), ("effective-due:-3 days", "effective_due_past_days"), ("deadline:3 days", "deadline_next_days"), (#"deadline on:"-3 days""#, "deadline_past_days")] {
            let rule = try parse(input)
            XCTAssertEqual(rule, .predicate(expected, "3"), input)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertTrue(rule.captureDefaults(in: context, today: "2026-10-05").isEmpty)
        }
        XCTAssertEqual(try parse("DATE: 0003 DAYS"), .predicate("planned_next_days", "3"))
        XCTAssertEqual(try parse("1 day"), .predicate("planned_next_days", "1"))
        XCTAssertEqual(try parse("date:in 3 days"), .predicate("planned_on", "in 3 days"))
        XCTAssertEqual(try parse("date:3 days ago"), .predicate("planned_on", "3 days ago"))
        XCTAssertEqual(try parse("created:-3 days"), .predicate("created_on", "3 days ago"))
        XCTAssertEqual(try parse("next 3 days"), .predicate("next", "3"))
        XCTAssertEqual(try parse("deadline:next3"), .predicate("deadline_next", "3"))
        let combined = try parse("(3 days | -3 days) & !completed, deadline:3 days")
        XCTAssertEqual(try parse(combined.expression(in: context)), combined)
    }
    func testDayWindowsRejectInvalidCountsAndNonRangeOperators() throws {
        for value in ["0", "-0", "3651", "-3651", "1.5", "+3", "--3", "999999999999999999999999999"] {
            for prefix in ["", "date:", "effective-due:", "deadline:"] { XCTAssertThrowsError(try parse(prefix + value + " days"), prefix + value) }
        }
        for input in ["date before:3 days", "date after:-3 days", "3 days p1", "3 days at 14:00", "date:3 days at 14:00", "3 weeks", "due:3 days"] { XCTAssertThrowsError(try parse(input), input) }
        for field in FilterDayWindow.expressions.keys {
            for value in ["", "0", "-3", "3651", "+3", "3 days", "3.0"] { XCTAssertThrowsError(try FilterRule(document: FilterRule.predicate(field, value).document), field + value) }
            XCTAssertNoThrow(try FilterRule(document: FilterRule.predicate(field, "3650").document))
        }
        XCTAssertEqual(try parse(#"search:"3 days""#), .predicate("search", "3 days"))
    }
    func testDayWindowsBoundariesMissingDatesAndEffectiveDuePrecedence() throws {
        let rows = [task("before", ["due_date": .string("2026-10-01")]), task("past-start", ["due_date": .string("2026-10-02")]), task("yesterday", ["due_date": .string("2026-10-04")]), task("today", ["due_date": .string("2026-10-05")]), task("last", ["due_date": .string("2026-10-07")]), task("outside", ["due_date": .string("2026-10-08")]), task("deadline", ["deadline_date": .string("2026-10-06")]), task("both", ["due_date": .string("2026-10-08"), "deadline_date": .string("2026-10-06")]), task("none")]
        for (input, ids) in [("3 days", ["today", "last"]), ("-3 days", ["past-start", "yesterday"]), ("effective-due:3 days", ["today", "last", "deadline"]), ("deadline:3 days", ["deadline", "both"]), ("1 day", ["today"]), ("-1 day", ["yesterday"])] {
            let rule = try parse(input); XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), ids, input)
        }
        XCTAssertTrue(matches(try parse("NOT 3 days"), task("none")))
        XCTAssertFalse(FilterDayWindow.matches("2026-10-05junk", field: "planned_next_days", value: "3", today: "2026-10-05", timeZone: "UTC"))
    }
    func testDayWindowsUseCivilDaysAcrossDSTLeapDaysAndViewerZones() throws {
        for zone in ["Europe/Copenhagen", "America/New_York", "Australia/Lord_Howe", "Pacific/Auckland", "Pacific/Honolulu"] {
            for (today, last, outside) in [("2026-03-28", "2026-03-30", "2026-03-31"), ("2026-10-24", "2026-10-26", "2026-10-27"), ("2028-02-28", "2028-03-01", "2028-03-02"), ("2026-12-30", "2027-01-01", "2027-01-02")] {
                let rule = try parse("3 days")
                for (day, expected) in [(today, true), (last, true), (outside, false)] {
                    XCTAssertEqual(rule.matches(task(day, ["due_date": .string(day)]), today: today, userID: "owner", labels: [], timeZone: zone), expected, "\(zone) \(today) \(day)")
                }
                let past = try parse("-3 days")
                XCTAssertTrue(past.matches(task("start", ["due_date": .string(today)]), today: outside, userID: "owner", labels: [], timeZone: zone))
                XCTAssertFalse(past.matches(task("end", ["due_date": .string(outside)]), today: outside, userID: "owner", labels: [], timeZone: zone))
            }
        }
        let fixed = task("fixed", ["due_date": .string("2026-10-05"), "due_time": .string("00:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-04T22:30:00Z")])
        XCTAssertTrue(matches(try parse("1 day"), fixed))
        XCTAssertFalse(matches(try parse("1 day"), fixed, zone: "America/New_York"))
        XCTAssertTrue(matches(try parse("-1 day"), fixed, zone: "America/New_York"))
    }
    func testDayWindowsRefreshCachePersistOfflineAndProjectPrivateWidgetDays() throws {
        let rule = try parse("effective-due:3 days")
        var row = task("target", ["deadline_date": .string("2026-10-07")])
        let cache = TaskCache(); cache.update([row])
        var query = TaskQuery(scope: .saved("window"), today: "2026-10-05", filter: rule, timeZone: "UTC")
        XCTAssertEqual(cache.matching(query).map(\.id), ["target"])
        query.today = "2026-10-08"; XCTAssertTrue(cache.matching(query).isEmpty)
        row["deadline_date"] = .string("2026-10-09"); cache.update([row]); XCTAssertEqual(cache.matching(query).map(\.id), ["target"])
        let view = Record(["id": .string("window"), "name": .string("Three days"), "query_ast": rule.document])
        let original = Snapshot(tables: ["tasks": [row], "saved_views": [view]], pending: [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try FilterRule(document: decoded.tables["saved_views"]![0]["query_ast"]), rule)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let payload = WidgetProjection.listPayload(tasks: [row], projects: [], labels: [], sections: [], savedViews: [view], account: "owner", now: Dates.parse("2026-10-05")!, calendar: calendar)
        let days = Record(payload[0].object)["days"].object
        XCTAssertEqual(days.count, 8)
        XCTAssertEqual(days["2026-10-06"]?.list.map(\.text), [])
        for day in ["2026-10-07", "2026-10-08", "2026-10-09"] { XCTAssertEqual(days[day]?.list.map(\.text), ["target"]) }
        XCTAssertEqual(days["2026-10-10"]?.list.map(\.text), [])
        XCTAssertFalse(String(data: try JSONEncoder().encode(payload), encoding: .utf8)!.contains("query_ast"))
    }

    func testQueryHeadingsUseAvailablePeopleWithoutRetargetingStoredIdentity() throws {
        let id = "22222222-2222-4222-8222-222222222222"
        let rule = FilterRule.sections([.predicate("assignee", id), .predicate("assignee", "others"), .predicate("assigned", "")])
        var context = FilterContext(people: [Record(["id": .string(id), "display_name": .string("Alex Smith")])])
        func groups(_ context: FilterContext) -> [TaskGrouping.Group] { TaskGrouping.queryGroups([], rule: rule, by: "none", context: context, today: "2026-10-07", timeZone: "UTC") }
        let before = groups(context)
        XCTAssertEqual(before.map(\.name), ["1 · Assigned to Alex Smith", "2 · Assigned to others", "3 · Assigned tasks"])
        context.people[0]["display_name"] = .string("Alex Renamed")
        XCTAssertEqual(groups(context)[0].name, "1 · Assigned to Alex Renamed")
        XCTAssertEqual(groups(context).map(\.id), before.map(\.id))
        XCTAssertEqual(groups(FilterContext())[0].name, "1 · Assigned to unavailable collaborator")
        XCTAssertEqual(try FilterRule(document: rule.document), rule)
        XCTAssertEqual(rule.expression(in: context), "assignee:" + id + ", assignee:others, assigned")
    }
    func testSeparateQueriesParseInOrderWithQuotedCommasAndBooleanPrecedence() throws {
        let input = #"search:"One, two", (p1 OR p2) & !assigned, date:tomorrow"#
        let rule = try parse(input)
        XCTAssertEqual(rule, .sections([.predicate("search", "One, two"), .and([.or([.predicate("priority", "1"), .predicate("priority", "2")]), .not(.predicate("assigned", ""))]), .predicate("planned_on", "tomorrow")]))
        XCTAssertEqual(try parse(rule.expression(in: context)), rule)
        XCTAssertEqual(try FilterRule(document: rule.document), rule)
        for bad in [", today", "today,", "today,,overdue", "(today, overdue)", "NOT (today, overdue)", "today AND , p1", Array(repeating: "all", count: 21).joined(separator: ",")] { XCTAssertThrowsError(try parse(bad), bad) }
        XCTAssertNoThrow(try parse(Array(repeating: "all", count: 20).joined(separator: ",")))
        for invalid in [FilterRule.sections([]), .sections([.predicate("all", "")]), .and([rule]), .not(rule), .sections([rule, .predicate("all", "")])] { XCTAssertThrowsError(try FilterRule(document: invalid.document)) }
        XCTAssertEqual(try parse("date:today, date:tomorrow").captureDefaults(in: context, today: "2026-10-07"), [:])
        XCTAssertEqual(try parse("#Work & p1, #Work & p2").captureDefaults(in: context, today: "2026-10-07"), ["project_id": .string("work-id")])
    }
    func testSeparateQueryGroupsRetainOverlapEmptyListsStableKeysAndCompletionScope() throws {
        let rows = [task("open", ["priority": .number(1)]), task("done", ["priority": .number(1), "completed": .bool(true)]), task("other", ["priority": .number(2)])]
        let rule = try parse("all, p1, completed, search:nothing, p1")
        let groups = TaskGrouping.queryGroups(rows, rule: rule, by: "none", context: context, today: "2026-10-07", timeZone: "UTC")
        XCTAssertEqual(groups.map { $0.tasks.map(\.id) }, [["open", "other"], ["open"], ["done"], [], ["open"]])
        XCTAssertEqual(groups.map(\.name), ["1 · all", "2 · p1", "3 · completed", "4 · search:\"nothing\"", "5 · p1"])
        XCTAssertEqual(Set(groups.map(\.id)).count, 5)
        let reordered = try parse("completed, p1, all, search:nothing, p1")
        let changed = TaskGrouping.queryGroups(rows, rule: reordered, by: "none", context: context, today: "2026-10-07", timeZone: "UTC")
        XCTAssertEqual(changed[0].id, groups[2].id); XCTAssertEqual(changed[2].id, groups[0].id)
        let included = TaskGrouping.queryGroups(rows, rule: rule, by: "none", context: context, today: "2026-10-07", timeZone: "UTC", includeCompleted: true)
        XCTAssertEqual(included[1].tasks.map(\.id), ["open", "done"])
        XCTAssertEqual(TaskGrouping.queryGroups([], rule: rule, by: "priority", context: context, today: "2026-10-07", timeZone: "UTC").count, 5)
        let projectRule = try parse("#Work, inbox")
        let renamed = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])])
        XCTAssertEqual(TaskGrouping.queryGroups([], rule: projectRule, by: "none", context: renamed, today: "2026-10-07", timeZone: "UTC").map(\.id), TaskGrouping.queryGroups([], rule: projectRule, by: "none", context: context, today: "2026-10-07", timeZone: "UTC").map(\.id))
    }
    func testSeparateQueryUnionWidgetProjectionAndOfflinePersistence() throws {
        let rule = try parse("p1, all, completed")
        let rows = [task("open", ["priority": .number(1)]), task("done", ["priority": .number(1), "completed": .bool(true)])]
        let cache = TaskCache(); cache.update(rows)
        XCTAssertEqual(Set(cache.matching(TaskQuery(scope: .saved("v"), filter: rule)).map(\.id)), ["open", "done"])
        let view = Record(["id": .string("v"), "name": .string("Queries"), "query_ast": rule.document])
        var snapshot = Snapshot(); snapshot.tables["saved_views"] = [view]
        snapshot.pending = [Mutation(table: "saved_views", recordID: "v", method: "POST", fields: view.fields)]
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.tables["saved_views"], [view]); XCTAssertEqual(decoded.pending[0].fields["query_ast"], rule.document)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let payload = WidgetProjection.listPayload(tasks: rows, projects: [], labels: [], sections: [], savedViews: [view], account: "a", now: Dates.parse("2026-10-07")!, calendar: calendar)
        let days = Record(payload[0].object)["days"].object
        XCTAssertEqual(days.count, 8); XCTAssertTrue(days.values.allSatisfy { $0.list.map(\.text) == ["open"] })
        XCTAssertFalse(String(data: try JSONEncoder().encode(payload), encoding: .utf8)!.contains("query_ast"))
        let noIdentity = try parse("NOT assignee:me, all")
        XCTAssertTrue(noIdentity.matches(rows[0], today: "2026-10-07", userID: "", labels: [], timeZone: "UTC"), "Independent safe query still matches; the Me query fails closed.")
    }


    func testAssignmentStatesAndMissingIdentityFailClosed() throws {
        let me = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let context = FilterContext(userID: me)
        func rule(_ input: String) throws -> FilterRule { var p = try FilterParser(input, context: context); return try p.parse() }
        let assigned = try rule("assigned"), others = try rule("assigned to: others")
        let rows = [task("mine", ["assigned_to": .string(me)]), task("other", ["assigned_to": .string(other)]), task("none", [:])]
        for (r, ids) in [(assigned, ["mine", "other"]), (others, ["other"]), (.not(assigned), ["none"]), (.not(others), ["mine", "none"])] {
            XCTAssertEqual(rows.filter { r.matches($0, today: "2026-10-07", userID: me, labels: [], timeZone: "UTC") }.map(\.id), ids)
            XCTAssertEqual(try FilterRule(document: r.document), r)
            XCTAssertEqual(try rule(r.expression(in: context)), r)
            XCTAssertTrue(r.captureDefaults(in: context, today: "2026-10-07").isEmpty)
        }
        for input in ["assignee:me", "assigned to:others", "NOT assignee:me", "all OR assignee:others"] {
            let r = try rule(input)
            XCTAssertFalse(r.matches(rows[2], today: "2026-10-07", userID: "", labels: [], timeZone: "UTC"))
        }
        XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("assigned"), "value": .string("yes")])))
    }
    func testNamedAssigneesResolveExactAcceptedCatalogAndRetainIdentity() throws {
        let id = "22222222-2222-4222-8222-222222222222"
        let me = "11111111-1111-4111-8111-111111111111"
        var context = FilterContext(userID: me, people: [Record(["id": .string(id), "display_name": .string("Alex Smith"), "email": .string("alex@example.test")]), Record(["id": .string(id), "display_name": .string("Alex Smith")]), Record(["id": .string(me), "display_name": .string("My Name")])])
        func parse(_ input: String, _ context: FilterContext) throws -> FilterRule { var p = try FilterParser(input, context: context); return try p.parse() }
        for input in [#"assigned to:"alex smith""#, "assigned to:alex@example.test", #"assignee:"Alex Smith""#, "assignee:" + id] {
            let r = try parse(input, context)
            XCTAssertEqual(r, .predicate("assignee", id))
            XCTAssertEqual(try parse(r.expression(in: context), FilterContext(userID: me)), r, "Stored UUID survives missing directory and renames")
        }
        XCTAssertEqual(try parse(#"assigned to:"My Name""#, context), .predicate("assignee", "me"))
        for input in [#"assigned to:"Alex""#, #"assigned to:"Alex*""#, "assigned by:me", "assigned to:nobody", "assigned to:"] { XCTAssertThrowsError(try parse(input, context)) }
        context.people.append(Record(["id": .string("33333333-3333-4333-8333-333333333333"), "display_name": .string("Alex Smith")]))
        XCTAssertThrowsError(try parse(#"assigned to:"Alex Smith""#, context))
        XCTAssertEqual(try parse("assigned to:alex@example.test", context), .predicate("assignee", id))
        let project = Record(["id": .string("p"), "user_id": .string(me)])
        let pending = Record(["user_id": .string(id), "status": .string("pending"), "display_name": .string("Alex Smith")])
        let people = TaskAssignment.members(project: project, collaborators: [pending], currentUser: me, profile: Record([:]))
        XCTAssertThrowsError(try parse(#"assigned to:"Alex Smith""#, FilterContext(userID: me, people: people)))
    }
    func testAssignmentQueriesShareWidgetMembershipAndOfflineCodec() throws {
        let me = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
        let rule = FilterRule.and([.predicate("assigned", ""), .predicate("assignee", "others")])
        let view = Record(["id": .string("assignment-view"), "name": .string("Delegated"), "query_ast": rule.document])
        let tasks = [task("mine", ["assigned_to": .string(me)]), task("delegated", ["assigned_to": .string(other)]), task("unassigned", [:])]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let payload = WidgetProjection.listPayload(tasks: tasks, projects: [], labels: [], sections: [], savedViews: [view], account: me, now: Dates.parse("2026-10-07")!, calendar: calendar)
        XCTAssertEqual(Record(payload[0].object)["days"].object.count, 8)
        XCTAssertTrue(Record(payload[0].object)["days"].object.values.allSatisfy { $0 == .array([.string("delegated")]) })
        let data = try JSONEncoder().encode(payload)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(other))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("query_ast"))
        var snapshot = Snapshot(); snapshot.tables["saved_views"] = [view]
        snapshot.pending = [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)]
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(try FilterRule(document: restored.tables["saved_views"]![0]["query_ast"]), rule)
        XCTAssertEqual(restored.pending[0].fields["query_ast"], rule.document)
    }


    func testNamePatternProjectionStaysBoundedWithThreeThousandTasksAndLongPatterns() throws {
        let rows = (0..<3000).map { task("volume-\($0)", ["project_id": .string("p")]) }
        let rule = FilterRule.predicate("project_name", String(repeating: "*a", count: 59) + "c")
        let cache = TaskCache(); cache.update(rows)
        let started = Date()
        for day in 7..<15 {
            let query = TaskQuery(scope: .all, today: String(format: "2026-10-%02d", day), filter: rule, filterProjects: [.init(id: "p", name: String(repeating: "a", count: 399) + "b")])
            XCTAssertTrue(cache.matching(query).isEmpty)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Name patterns must resolve against the catalog, not once per task.")
    }
    func testNamePatternsAnchorFoldEscapeAndBoundWork() throws {
        for (name, pattern, expected) in [("Network", "*Work", true), ("Artwork admin", "*Work", false), ("HOMEoffice", "home*", true), ("Café meeting", "cafe*", true), ("Admin Work Calls", "*Work*", true), ("Urgent", "urgent*", true), ("Work*", #"Work\*"#, true), ("Working", #"Work\*"#, false), ("a\\b", #"a\\b"#, true), ("abcd", "a**d", true), ("ab", "a?", false)] {
            XCTAssertEqual(FilterNamePattern.matches(name, pattern: pattern), expected, "\(name) / \(pattern)")
        }
        for value in ["", " \n ", "abc\nxyz", String(repeating: "*", count: 121), #"bad\q"#, "bad\\"] { XCTAssertThrowsError(try FilterNamePattern.canonical(value)) }
        XCTAssertFalse(FilterNamePattern.matches(String(repeating: "x", count: 401), pattern: "*"))
        XCTAssertFalse(FilterNamePattern.matches(String(repeating: "a", count: 399) + "b", pattern: String(repeating: "*a", count: 59) + "c"))
    }
    func testNamePatternParserSeparatesLiteralIDsAndDynamicPatterns() throws {
        let literal = FilterContext(projects: [Record(["id": .string("literal"), "name": .string("Work*")])], labels: [Record(["id": .string("star"), "name": .string("home*")])])
        for (input, field, value) in [("#*Work", "project_name", "*Work"), ("%home*", "label_name", "home*"), ("@home*", "label_name", "home*"), ("/*Work*", "section_name", "*Work*"), ("/Meetings", "section_name", "Meetings"), (#"project matching:"*Work Admin*""#, "project_name", "*Work Admin*"), (#"label matching:"AND*""#, "label_name", "AND*")] {
            let rule = try parse(input)
            XCTAssertEqual(rule, .predicate(field, value))
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertTrue(rule.captureDefaults(in: context, today: "2026-10-07").isEmpty)
        }
        XCTAssertEqual(try parse(#"#"Work*""#, context: literal), .predicate("project", "literal"))
        XCTAssertEqual(try parse(#"%"home*""#, context: literal), .predicate("label", "star"))
        XCTAssertThrowsError(try parse("##Work"))
        for field in FilterNamePattern.expressions.keys {
            for value: JSON in [.null, .number(1), .string("")] { XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string(field), "value": value]))) }
        }
    }
    func testNamePatternsRespectCatalogIdentityLegacyLabelsAndMissingReferencesUnderNegation() throws {
        let projects = [FilterReference(id: "p", name: "Network")], sections = [FilterReference(id: "s", name: "Work Calls")], labels = [FilterReference(id: "l", name: "Homeoffice")]
        let row = task("work", ["project_id": .string("p"), "section_id": .string("s"), "labels": .array([.string("l")])])
        func check(_ input: String, _ task: Record, _ p: [FilterReference] = projects, _ s: [FilterReference] = sections, _ l: [FilterReference] = labels) throws -> Bool {
            try parse(input).matches(task, today: "2026-10-07", userID: "owner", labels: l, timeZone: "UTC", projects: p, sections: s)
        }
        XCTAssertTrue(try check("#*Work & /*Calls & %home*", row))
        var legacy = row; legacy["labels"] = .array([.string("Homeoffice")]); XCTAssertTrue(try check("%home*", legacy))
        XCTAssertFalse(try check("!#*Work", row, [])); XCTAssertFalse(try check("!/*", row, projects, []))
        XCTAssertFalse(try check("!%home*", row, projects, sections, []))
        XCTAssertFalse(try check("!#*Work | all", row, []))
        XCTAssertFalse(try check("!%home*", row, [], sections, labels))
        XCTAssertFalse(try check("!/*", row, projects, [FilterReference(id: "s", name: "Work Calls", projectID: "another-project")], labels))
        XCTAssertTrue(try check("!/*", task("inbox"), [], [], []))
        XCTAssertFalse(try check("/*", task("inbox"), [], [], []))
        XCTAssertTrue(try check("!#*School", row))
        XCTAssertFalse(try check("%home*", row, projects, sections, [FilterReference(id: "other-account-label", name: "Homeoffice")]))
    }
    func testNamePatternCacheReevaluatesRenamesNewTargetsAndRevocationWithoutTaskMutation() throws {
        let cache = TaskCache(), row = task("task", ["project_id": .string("p")])
        cache.update([row])
        var query = TaskQuery(scope: .all, filter: try parse("#*Work"), filterProjects: [FilterReference(id: "p", name: "Artwork")])
        XCTAssertEqual(cache.matching(query).map(\.id), [row.id]); let count = cache.computationCount
        query.filterProjects[0].name = "Studio"; XCTAssertTrue(cache.matching(query).isEmpty); XCTAssertGreaterThan(cache.computationCount, count)
        query.filterProjects += [FilterReference(id: "new", name: "Network")]; var next = row; next["id"] = .string("next"); next["project_id"] = .string("new"); cache.update([row, next]); XCTAssertEqual(cache.matching(query).map(\.id), [next.id])
        query.filter = try parse("!#*Work"); query.filterProjects = []; XCTAssertTrue(cache.matching(query).isEmpty)
        XCTAssertEqual(cache.tasks.first { $0.id == row.id }, row)
        let snapshot = Snapshot(tables: ["saved_views": [Record(["id": .string("names"), "query_ast": query.filter!.document])]], pending: [Mutation(table: "saved_views", recordID: "names", method: "PATCH", fields: ["query_ast": query.filter!.document])])
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func testNamePatternWidgetMembershipUsesSameCatalogAndPublishesNoPatterns() throws {
        let row = task("visible", ["project_id": .string("p"), "section_id": .string("s"), "labels": .array([.string("Waiting")])])
        let rule = try parse("#*Work & /Calls & %wait*")
        let projects = [Record(["id": .string("p"), "name": .string("Artwork")])], sections = [Record(["id": .string("s"), "name": .string("Calls")])], labels = [Record(["id": .string("l"), "name": .string("Waiting")])]
        let views = [Record(["id": .string("v"), "name": .string("Work calls"), "query_ast": rule.document])]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(Dates.parse("2026-10-07", calendar: calendar))
        let payload = WidgetProjection.listPayload(tasks: [row], projects: projects, labels: labels, sections: sections, savedViews: views, account: "owner", now: now, calendar: calendar)
        let filter = try XCTUnwrap(payload.first { $0.object["kind"] == .string("filter") })
        XCTAssertEqual(filter.object["days"]?.object.count, 8)
        for ids in filter.object["days"]!.object.values { XCTAssertEqual(ids.list, [.string(row.id)]) }
        let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(encoded.contains("query_ast")); XCTAssertFalse(encoded.contains("*Work")); XCTAssertFalse(encoded.contains("wait*"))
        let revoked = WidgetProjection.listPayload(tasks: [row], projects: [], labels: labels, sections: sections, savedViews: views, account: "owner", now: now, calendar: calendar)
        let revokedFilter = try XCTUnwrap(revoked.first { $0.object["kind"] == .string("filter") })
        XCTAssertTrue(revokedFilter.object["days"]!.object.values.allSatisfy { $0.list.isEmpty })
    }
    func testCreationExpressionsCanonicalizeAndRoundTripWithoutChangingOldDateFields() throws {
        for (input, field, value) in [("created:today", "created_on", "today"), ("created on:Jan 3 2023", "created_on", "jan 3 2023"), ("created before: -365 days", "created_before", "365 days ago"), ("created after: yesterday", "created_after", "yesterday"), ("created:-0 days", "created_on", "today"), (#"created after:"in 3 days""#, "created_after", "in 3 days")] {
            let rule = try parse(input)
            XCTAssertEqual(rule, .predicate(field, value), input)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertTrue(rule.captureDefaults(in: context, today: "2026-10-05").isEmpty)
        }
        XCTAssertEqual(try parse("due:2026-10-05"), .predicate("due", "2026-10-05"))
        XCTAssertEqual(try parse("created before:-30 days AND #Work").captureDefaults(in: context, today: "2026-10-05"), ["project_id": .string("work-id")])
        for value in ["-3651 days", "--1 days", "-1.5 days", "-１ days", "- days", "today at 14:00", "2026-02-30", "", "tomorrow nonsense"] { XCTAssertThrowsError(try parse("created:" + value), value) }
        for value: JSON in [.null, .number(2), .bool(true), .array([])] {
            XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("created_on"), "value": value])))
        }
    }
    func testCreationFeedbackDoesNotSuggestUnsupportedTimesOrAnotherDateSource() throws {
        for value in ["today at 14:00", "today at 25:00", "bad date", "", "2026-02-30"] {
            XCTAssertThrowsError(try FilterCreationReference.canonical(value)) { error in
                XCTAssertEqual(error.localizedDescription, "Enter a creation date without a time. Try today, yesterday or -30 days.")
            }
        }
    }
    func testCreationDatesUseViewerDayExclusiveBoundariesAndNeverPlanningFallback() throws {
        let rows = [task("before", ["created_at": .string("2026-10-04T21:59:59.999Z")]), task("start", ["created_at": .string("2026-10-04T22:00:00Z")]), task("end", ["created_at": .string("2026-10-05T23:59:59+02:00")]), task("after", ["created_at": .string("2026-10-05T22:00:00Z")]), task("legacy", ["created_at": .string("2026-10-05")]), task("unknown", ["due_date": .string("2026-10-05"), "deadline_date": .string("2026-10-05")])]
        for (expression, expected) in [("created:today", ["start", "end", "legacy"]), ("created before:today", ["before"]), ("created after:today", ["after"])] {
            let rule = try parse(expression)
            XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected, expression)
        }
        XCTAssertEqual(rows.filter { matches(try! parse("created:today"), $0, zone: "UTC") }.map(\.id), ["end", "after", "legacy"])
        for value in ["", "not a date", "2026-02-30T12:00:00Z", "2026-10-05T24:00:00Z", "2026-10-05T12:60:00Z", "2026-10-05T12:00:00", "2026-10-05T12:00:00Z junk"] { XCTAssertNil(FilterCreationReference.day(task("invalid", ["created_at": .string(value)]), timeZone: "UTC"), value) }
        XCTAssertNil(FilterCreationReference.day(rows[1], timeZone: "Invented/Zone"))
    }
    func testCreationDatesHandleDSTFoldsHalfHourTravelAndCalendarOffsets() throws {
        for (zone, instant, day) in [("Europe/Copenhagen", "2026-10-25T00:30:00Z", "2026-10-25"), ("Europe/Copenhagen", "2026-10-25T01:30:00Z", "2026-10-25"), ("Europe/Copenhagen", "2026-03-29T22:00:00Z", "2026-03-30"), ("Australia/Lord_Howe", "2026-10-03T13:30:00Z", "2026-10-04"), ("Pacific/Honolulu", "2026-10-05T00:30:00Z", "2026-10-04"), ("Pacific/Apia", "2011-12-30T10:00:00Z", "2011-12-31")] {
            XCTAssertEqual(FilterCreationReference.day(task("timed", ["created_at": .string(instant)]), timeZone: zone), day)
        }
        XCTAssertEqual(FilterDateReference.day(try FilterCreationReference.canonical("-1 days"), today: "2026-03-30", timeZone: "Europe/Copenhagen"), "2026-03-29")
        XCTAssertEqual(FilterDateReference.day(try FilterCreationReference.canonical("-1 days"), today: "2024-03-01", timeZone: "Australia/Lord_Howe"), "2024-02-29")
    }
    func testCreationMembershipInvalidatesForDayZoneAndMetadataEditsWithoutRewritingQueuedQuery() throws {
        let rule = try parse("created:today")
        var row = task("creation", ["created_at": .string("2026-10-04T22:30:00Z")]); let cache = TaskCache(); cache.update([row])
        var query = TaskQuery(scope: .saved("creation"), today: "2026-10-05", filter: rule, timeZone: "Europe/Copenhagen")
        XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        query.timeZone = "UTC"; XCTAssertTrue(cache.matching(query).isEmpty)
        query.today = "2026-10-04"; XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        row["created_at"] = .string("2026-10-05T22:30:00Z"); cache.update([row]); XCTAssertTrue(cache.matching(query).isEmpty)
        let view = Record(["id": .string("creation"), "name": .string("New work"), "query_ast": rule.document])
        let original = Snapshot(tables: ["tasks": [row], "saved_views": [view]], pending: [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original); XCTAssertEqual(decoded.pending[0].fields["query_ast"], rule.document)
    }

    let context = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Work")])], sections: [Record(["id": .string("section-id"), "name": .string("Next steps")])], labels: [Record(["id": .string("waiting-id"), "name": .string("waiting")])], userID: "owner")
    func parse(_ input: String, context: FilterContext? = nil) throws -> FilterRule { var parser = try FilterParser(input, context: context ?? self.context); return try parser.parse() }
    func task(_ id: String, _ fields: [String: JSON] = [:]) -> Record { var row = Record(["id": .string(id), "title": .string(id), "completed": .bool(false), "priority": .number(4)]); for (key, value) in fields { row[key] = value }; return row }
    func matches(_ rule: FilterRule, _ row: Record, labels: [FilterReference] = [FilterReference(id: "waiting-id", name: "waiting")], zone: String = "Europe/Copenhagen") -> Bool { rule.matches(row, today: "2026-10-05", userID: "owner", labels: labels, timeZone: zone) }


    func testCalendarContextSeparatesClockTicksDayBoundariesAndSameDayZoneChanges() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-28T22:59:59Z"))
        let copenhagen = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let before = TaskCalendarContext(now: date, timeZone: copenhagen)
        XCTAssertEqual(before.today, "2026-03-28")
        XCTAssertEqual(TaskCalendarContext(now: date.addingTimeInterval(-10), timeZone: copenhagen), before)
        let after = TaskCalendarContext(now: date.addingTimeInterval(1), timeZone: copenhagen)
        XCTAssertEqual(after.today, "2026-03-29"); XCTAssertNotEqual(after, before)
        let utc = TaskCalendarContext(now: date, timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)))
        XCTAssertEqual(utc.today, before.today); XCTAssertNotEqual(utc, before, "A same-day zone change still changes fixed-time membership")
        XCTAssertEqual(TaskCalendarContext.refreshDelay(after: date, timeZone: copenhagen), 1, accuracy: 0.001)
        XCTAssertEqual(TaskCalendarContext.refreshDelay(after: date.addingTimeInterval(1), timeZone: copenhagen), 60)
    }
    func testCalendarContextUsesCivilMidnightThroughNonHourDSTAndSkippedDays() throws {
        for (zone, instant, today, nextDay) in [
            ("Europe/Copenhagen", "2026-03-29T21:59:59Z", "2026-03-29", "2026-03-30"),
            ("Europe/Copenhagen", "2026-10-25T22:59:59Z", "2026-10-25", "2026-10-26"),
            ("Australia/Lord_Howe", "2026-10-04T12:59:59Z", "2026-10-04", "2026-10-05"),
            ("Pacific/Apia", "2011-12-30T09:59:59Z", "2011-12-29", "2011-12-31")
        ] {
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: instant)), timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            XCTAssertEqual(TaskCalendarContext(now: now, timeZone: timeZone).today, today, zone)
            XCTAssertEqual(TaskCalendarContext(now: now.addingTimeInterval(1), timeZone: timeZone).today, nextDay, zone)
            XCTAssertEqual(TaskCalendarContext.refreshDelay(after: now, timeZone: timeZone), 1, accuracy: 0.001, zone)
        }
    }
    func testCalendarContextInvalidatesMembershipWithoutTaskEditsAndPreservesSelectedDay() throws {
        var snapshot = Snapshot()
        snapshot.tables["tasks"] = [task("calendar-clock-0", ["due_date": .string("2026-03-28"), "title": .string("Yesterday plan")]),
            task("calendar-clock-1", ["due_date": .string("2026-03-29"), "title": .string("Today plan A")]),
            task("calendar-clock-2", ["due_date": .string("2026-03-29"), "title": .string("Today plan B")]),
            task("calendar-clock-3", ["due_date": .string("2026-03-29"), "title": .string("Today plan C")]),
            task("calendar-clock-4", ["due_date": .string("2026-03-29"), "due_time": .string("01:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-03-29T00:30:00Z"), "title": .string("Fixed Copenhagen plan")])]
        let cache = TaskCache()
        cache.update(snapshot.tables["tasks"] ?? [])
        let original = snapshot
        var query = TaskQuery(scope: .all); query.filter = .predicate("planned_on", "today"); query.sort = "title"
        let stages = [("2026-03-28T22:59:59Z", "Europe/Copenhagen", ["calendar-clock-0"]),
                      ("2026-03-28T23:00:00Z", "Europe/Copenhagen", ["calendar-clock-4", "calendar-clock-1", "calendar-clock-2", "calendar-clock-3"]),
                      ("2026-03-28T23:00:00Z", "Pacific/Honolulu", ["calendar-clock-4", "calendar-clock-0"]),
                      ("2026-03-29T10:00:00Z", "Pacific/Honolulu", ["calendar-clock-1", "calendar-clock-2", "calendar-clock-3"])]
        for (instant, zone, expected) in stages {
            let context = TaskCalendarContext(now: try XCTUnwrap(ISO8601DateFormatter().date(from: instant)), timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
            let current = context.applying(to: query)
            XCTAssertEqual(cache.matching(current).map(\.id), expected)
            XCTAssertEqual(cache.matching(current).map(\.id), expected)
            var selected = TaskQuery(scope: .upcoming); selected.selectedDay = "2026-03-28"
            XCTAssertEqual(context.applying(to: selected).selectedDay, "2026-03-28")
            XCTAssertEqual(FilterRule.predicate("planned_on", "tomorrow").captureDefaults(in: self.context, today: context.today, timeZone: context.timeZone)["due_date"]?.text, context.today == "2026-03-28" ? "2026-03-29" : "2026-03-30")
        }
        XCTAssertEqual(cache.computationCount, 4); XCTAssertEqual(snapshot, original)
    }

    func testExplicitDateSourcesPreferPlansAndPreserveLegacyDocuments() throws {
        let rows = [task("plan", ["due_date": .string("2026-10-05")]), task("deadline", ["deadline_date": .string("2026-10-05")]), task("both", ["due_date": .string("2026-10-06"), "deadline_date": .string("2026-10-05")]), task("neither")]
        for (expression, expected) in [("date:today", ["plan"]), ("effective-due:today", ["plan", "deadline"]), ("deadline on:today", ["deadline", "both"]), ("effective-due:tomorrow", ["both"]), ("due:2026-10-05", ["plan"]), ("today", ["plan"]), ("no date", ["deadline", "neither"])] {
            let rule = try parse(expression)
            XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected, expression)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
        }
        let legacy: JSON = .object(["version": .number(1), "root": .object(["op": .string("predicate"), "field": .string("due"), "value": .string("2026-10-05")])])
        let old = try FilterRule(document: legacy)
        XCTAssertEqual(old.document, legacy); XCTAssertFalse(matches(old, rows[1]))
        XCTAssertEqual(try parse("before:2026-10-06"), .predicate("before", "2026-10-06"))
        XCTAssertEqual(try parse("deadline:today"), .predicate("deadline_today", ""))
        XCTAssertEqual(try parse("deadline:next7"), .predicate("deadline_next", "7"))
    }
    func testBeforeAndAfterExcludeBoundariesAndNeverMatchUndatedTasks() throws {
        let rows = [task("before", ["due_date": .string("2026-10-04"), "deadline_date": .string("2026-10-06")]), task("on", ["due_date": .string("2026-10-05"), "deadline_date": .string("2026-10-05")]), task("after", ["due_date": .string("2026-10-06"), "deadline_date": .string("2026-10-04")]), task("fallback", ["deadline_date": .string("2026-10-04")]), task("none")]
        for (expression, expected) in [("date before: today", ["before"]), ("date after:today", ["after"]), ("effective-due before:today", ["before", "fallback"]), ("effective-due after:today", ["after"]), ("deadline before:today", ["after", "fallback"]), ("deadline after:today", ["before"])] {
            let rule = try parse(expression)
            XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected, expression)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
        }
    }
    func testDatePhrasesStayRelativeAcrossMidnightLeapDaysAndZones() throws {
        let tomorrow = try parse("date: tomorrow")
        let nextDay = task("tomorrow", ["due_date": .string("2026-10-06")])
        XCTAssertTrue(matches(tomorrow, nextDay))
        XCTAssertFalse(tomorrow.matches(nextDay, today: "2026-10-06", userID: "owner", labels: [], timeZone: "Europe/Copenhagen"))
        XCTAssertEqual(tomorrow.document.object["root"]?.object["value"], .string("tomorrow"))
        for zone in ["Europe/Copenhagen", "America/New_York", "Australia/Lord_Howe", "Pacific/Auckland", "Pacific/Honolulu"] {
            for (today, phrase, expected) in [("2026-10-24", "tomorrow", "2026-10-25"), ("2026-10-25", "in 7 days", "2026-11-01"), ("2026-04-04", "tomorrow", "2026-04-05"), ("2028-02-28", "tomorrow", "2028-02-29"), ("2028-03-01", "1 day ago", "2028-02-29"), ("2026-10-05", "Monday", "2026-10-05"), ("2026-10-05", "next Monday", "2026-10-12"), ("2026-10-05", "January 3", "2027-01-03"), ("2026-10-05", "6 October 2026", "2026-10-06")] {
                let value = try FilterDateReference.canonical(phrase)
                XCTAssertEqual(FilterDateReference.day(value, today: today, timeZone: zone), expected, "\(zone) \(today) \(phrase)")
            }
        }
        XCTAssertEqual(try parse("date: IN   7 DAYS"), .predicate("planned_on", "in 7 days"))
        XCTAssertEqual(try parse("date:0 days ago"), .predicate("planned_on", "today"))
        XCTAssertEqual(try parse(#"date:"Jan 3, 2027" AND NOT no date"#), .and([.predicate("planned_on", "jan 3, 2027"), .not(.predicate("no_date", ""))]))
    }
    func testDateSourceUsesViewerDayForFixedPlansAndFloatingDeadlineFallback() throws {
        let fixed = task("fixed", ["due_date": .string("2026-10-05"), "due_time": .string("00:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-04T22:30:00Z"), "deadline_date": .string("2026-10-05")])
        for expression in ["date:today", "effective-due:today"] {
            let rule = try parse(expression)
            XCTAssertTrue(matches(rule, fixed)); XCTAssertFalse(matches(rule, fixed, zone: "America/New_York"))
        }
        var floating = fixed; floating["time_zone"] = .null; floating["scheduled_at"] = .null
        XCTAssertTrue(matches(try parse("effective-due:today"), floating, zone: "America/New_York"))
        floating["due_date"] = .null; floating["due_time"] = .null
        XCTAssertTrue(matches(try parse("effective-due:today"), floating, zone: "America/New_York"))
        XCTAssertFalse(matches(try parse("date:today"), floating, zone: "America/New_York"))
    }
    func testDateGrammarRejectsAmbiguousWindowsMalformedValuesAndUnsupportedSections() throws {
        for expression in ["date:", "date:2026-02-30", "date:2026-10-05T12:00:00Z", "date:31 February", "date:+4 hours", "date:in 3651 days", "date:today at 25:00", "date:today p1", "effective-due before:"] { XCTAssertThrowsError(try parse(expression), expression) }
        for value: JSON in [.null, .number(1), .bool(true), .array([])] {
            XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("planned_on"), "value": value])))
        }
        XCTAssertThrowsError(try FilterRule(document: .object(["version": .number(2), "root": FilterRule.predicate("planned_on", "tomorrow").json])))
        let mixed = try parse("(date: tomorrow OR deadline after: in 7 days) AND search:email")
        XCTAssertEqual(try parse(mixed.expression(in: context)), mixed)
    }
    func testDateCaptureDefaultsDoNotChooseAPlanForDeadlineFallbackOrWindows() throws {
        XCTAssertEqual(try parse("date:tomorrow").captureDefaults(in: context, today: "2026-10-05", timeZone: "Australia/Lord_Howe"), ["due_date": .string("2026-10-06")])
        XCTAssertEqual(try parse("deadline on:in 7 days").captureDefaults(in: context, today: "2026-10-05"), ["deadline_date": .string("2026-10-12")])
        for expression in ["effective-due:today", "effective-due before:tomorrow", "effective-due after:yesterday", "date before:tomorrow", "deadline after:today", "NOT date:tomorrow", "date:tomorrow OR date:today", "date:tomorrow AND date:today"] {
            XCTAssertTrue(try parse(expression).captureDefaults(in: context, today: "2026-10-05").isEmpty, expression)
        }
    }
    func testRelativeDateCacheAndOfflineDocumentsRetainCurrentDayAndDeadlineEdits() throws {
        let rule = try parse("effective-due:tomorrow")
        var row = task("deadline", ["deadline_date": .string("2026-10-06")])
        let cache = TaskCache(); cache.update([row])
        var query = TaskQuery(scope: .saved("date-filter"), today: "2026-10-05"); query.filter = rule
        XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        query.today = "2026-10-06"; XCTAssertTrue(cache.matching(query).isEmpty)
        row["deadline_date"] = .string("2026-10-07"); cache.update([row]); XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        row["due_date"] = .string("2026-10-06"); cache.update([row]); XCTAssertTrue(cache.matching(query).isEmpty)
        let view = Record(["id": .string("date-filter"), "name": .string("Tomorrow"), "user_id": .string("owner"), "query_ast": rule.document])
        let original = Snapshot(tables: ["tasks": [row], "saved_views": [view]], pending: [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try FilterRule(document: decoded.tables["saved_views"]![0]["query_ast"]), rule)
        XCTAssertEqual(decoded.pending[0].fields["query_ast"], rule.document)
    }

    func testCommonFilterCorpusAndOperatorPrecedence() throws {
        let rows = [task("overdue", ["due_date": .string("2026-10-04")]), task("today", ["due_date": .string("2026-10-05"), "priority": .number(1)]), task("later", ["due_date": .string("2026-10-06"), "project_id": .string("work-id"), "priority": .number(1)]), task("plain"), task("waiting", ["labels": .array([.string("waiting")])])]
        for (expression, expected) in [("today OR overdue", ["overdue", "today"]), ("project:Work AND p1", ["later"]), (#"no date AND NOT label:"waiting""#, ["plain"]), ("overdue OR today AND p1", ["overdue", "today"]), ("(overdue OR today) AND p1", ["today"]), ("next 2 days", ["today", "later"])] {
            let rule = try parse(expression); XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected, expression)
        }
    }
    func testStableTargetsSurviveRenameAndRejectDeletionIncludingNegation() throws {
        let rule = try parse("project:Work AND NOT label:waiting")
        let renamed = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])], labels: context.labels)
        XCTAssertNoThrow(try rule.validate(in: renamed)); XCTAssertEqual(try parse(rule.expression(in: renamed), context: renamed), rule)
        XCTAssertThrowsError(try rule.validate(in: FilterContext(projects: renamed.projects)))
        XCTAssertThrowsError(try FilterRule.not(.predicate("project", "missing")).validate(in: context))
    }
    func testQuotedTargetsAndDuplicateNamesRoundTripWithoutRetargeting() throws {
        let weird = Record(["id": .string("weird-id"), "name": .string(#"Work "A" & (B)"#)])
        let c = FilterContext(projects: [weird, Record(["id": .string("first"), "name": .string("Same")]), Record(["id": .string("second"), "name": .string("Same")])])
        for id in [weird.id, "first", "second"] { let rule = FilterRule.predicate("project", id); XCTAssertEqual(try parse(rule.expression(in: c), context: c), rule) }
        XCTAssertThrowsError(try parse("project:Same", context: c))
    }
    func testMalformedExpressionsAndUntrustedDocumentsStayInvalid() throws {
        for expression in ["", "today tomorrow", "today OR", "NOT", "(today", "today)", "p0", "next 0 days", "duration<=0", "deadline:2026-02-30", "assignee:nobody", #"project:"unclosed"#] { XCTAssertThrowsError(try parse(expression), expression) }
        for document: JSON in [.object([:]), .object(["version": .number(2), "root": FilterRule.predicate("all", "").json]), .object(["version": .number(1), "root": .object(["op": .string("all")])])] { XCTAssertThrowsError(try FilterRule(document: document)) }
        XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("and"), "children": .array([])])))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("assignee", "not-an-id").json))
        XCTAssertThrowsError(try parse(String(repeating: "NOT ", count: 25) + "today"))
    }
    func testDeadlinesAreIndependentAndUnknownEstimatesDoNotFitSmallWindow() throws {
        let row = task("report", ["due_date": .string("2026-10-08"), "deadline_date": .string("2026-10-05"), "duration_minutes": .number(25)])
        XCTAssertTrue(matches(try parse("deadline:today AND duration<=25"), row))
        XCTAssertFalse(matches(try parse("today"), row)); XCTAssertFalse(matches(try parse("duration<=10"), row))
        XCTAssertFalse(matches(try parse("duration<=25"), task("unknown")))
        XCTAssertTrue(matches(try parse("no estimate AND no deadline"), task("unknown")))
        XCTAssertTrue(matches(try parse("deadline:next7"), row))
    }
    func testAssignmentUsesCurrentAccountAndCompletionHasExplicitOptIn() throws {
        XCTAssertTrue(matches(try parse("assignee:me"), task("mine", ["assigned_to": .string("owner")])))
        XCTAssertFalse(matches(try parse("assignee:me"), task("other", ["assigned_to": .string("other")])))
        XCTAssertTrue(matches(try parse("assignee:unassigned"), task("none")))
        XCTAssertTrue(try parse("completed OR today").includesCompletion)
        XCTAssertFalse(try parse("today").includesCompletion)
        let cache = TaskCache(); cache.update([task("done", ["completed": .bool(true)]), task("open")])
        var query = TaskQuery(scope: .saved("example")); query.filter = try parse("completed"); query.includeCompleted = true
        XCTAssertEqual(cache.matching(query).map(\.id), ["done"])
    }
    func testFixedPlanFiltersFollowLocalDayWhileFloatingDatesStayPut() throws {
        let fixed = task("fixed", ["due_date": .string("2026-10-05"), "due_time": .string("00:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-04T22:30:00Z")])
        let rule = try parse("today")
        XCTAssertTrue(matches(rule, fixed)); XCTAssertFalse(matches(rule, fixed, zone: "America/New_York"))
        XCTAssertTrue(matches(rule, task("floating", ["due_date": .string("2026-10-05"), "due_time": .string("00:30")]), zone: "America/New_York"))
        let cache = TaskCache(); cache.update([fixed]); var query = TaskQuery(scope: .saved("local-day"), today: "2026-10-05"); query.filter = rule; query.timeZone = "America/New_York"
        XCTAssertTrue(cache.matching(query).isEmpty); query.timeZone = "Europe/Copenhagen"; XCTAssertEqual(cache.matching(query).map(\.id), ["fixed"])
    }
    func testCacheIncludesRuleAndReferenceChanges() throws {
        let cache = TaskCache(); cache.update([task("one", ["labels": .array([.string("waiting")])]), task("two")])
        var query = TaskQuery(scope: .saved("example")); query.filter = try parse("label:waiting"); query.filterLabels = [FilterReference(id: "waiting-id", name: "waiting")]
        XCTAssertEqual(cache.matching(query).map(\.id), ["one"])
        query.filterLabels = [FilterReference(id: "waiting-id", name: "renamed")]; XCTAssertTrue(cache.matching(query).isEmpty)
        query.filter = try parse("no date"); XCTAssertEqual(cache.matching(query).count, 2)
    }
    func testOrganizationRecordsAndOfflineQueueSurviveAccountCacheRoundTrip() throws {
        let rule = try parse("today OR overdue")
        let view = Record(["id": .string("filter-id"), "user_id": .string("owner"), "name": .string("Focus"), "query_ast": rule.document, "layout": .string("board"), "grouping": .string("priority")])
        let records = ["saved_views": [view], "favorites": [Record(["id": .string("view:filter-id"), "user_id": .string("owner"), "order_index": .number(0)])], DayPlacement.table: [Record(["id": .string("scope:view:filter-id:group:all"), "user_id": .string("owner"), "ids": .array([.string("b"), .string("a")])])]]
        let queue = records.flatMap { table, rows in rows.map { Mutation(table: table, recordID: $0.id, method: "POST", fields: $0.fields) } }
        let snapshot = Snapshot(tables: records, pending: queue)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)); XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(try FilterRule(document: decoded.tables["saved_views"]![0]["query_ast"]), rule)
        XCTAssertEqual(TaskScope(preferenceKey: "view:filter-id"), .saved("filter-id")); XCTAssertNil(TaskScope(preferenceKey: "view:"))
        XCTAssertEqual(DayPlacement.table, "view_orders")
    }
    func testCaptureDefaultsStayConservativeAcrossBooleanConditions() throws {
        let work = try parse("project:Work AND p1 AND today AND label:waiting")
        let defaults = work.captureDefaults(in: context, today: "2026-10-05")
        XCTAssertEqual(defaults["project_id"], .string("work-id")); XCTAssertEqual(defaults["priority"], .number(1)); XCTAssertEqual(defaults["due_date"], .string("2026-10-05")); XCTAssertEqual(defaults["labels"], .array([.string("waiting")]))
        XCTAssertTrue(try parse("today OR overdue").captureDefaults(in: context, today: "2026-10-05").isEmpty)
        XCTAssertNil(try parse("duration<=25 AND next 7 days").captureDefaults(in: context, today: "2026-10-05")["duration_minutes"])
        XCTAssertNil(try parse("p1 AND p2").captureDefaults(in: context, today: "2026-10-05")["priority"])
        XCTAssertEqual(try parse("(project:Work AND today) OR (project:Work AND overdue)").captureDefaults(in: context, today: "2026-10-05"), ["project_id": .string("work-id")])
    }
    func testGroupingHasStableIDsAcrossProjectRenameAndUnknownDates() {
        let rows = [task("one", ["project_id": .string("work-id")]), task("two")]
        let before = TaskGrouping.groups(rows, by: "project", projects: context.projects)
        let after = TaskGrouping.groups(rows, by: "project", projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])])
        XCTAssertEqual(before.map(\.id), after.map(\.id)); XCTAssertEqual(after.first(where: { $0.id == "project:work-id" })?.name, "Renamed")
        XCTAssertEqual(TaskGrouping.groups(rows, by: "deadline", projects: []).first?.name, "No deadline")
    }
    func testKeywordSearchUsesEveryWordAcrossTitleAndDescriptionWithInvariantFolding() throws {
        let rule = try parse("search: EMAIL cafe")
        var row = task("Cafe meeting", ["description": .string("Send the email agenda")])
        XCTAssertTrue(matches(rule, row))
        row["title"] = .string("CAFÉ MEETING"); XCTAssertTrue(matches(rule, row))
        row["description"] = .string("Email goes here"); XCTAssertTrue(matches(try parse("search: café email"), row))
        XCTAssertFalse(matches(try parse("search: email missing"), row))
        row["description"] = .string(""); row["comments"] = .array([.object(["text": .string("email")])])
        XCTAssertFalse(matches(rule, row), "Comments are outside the keyword condition")
        XCTAssertTrue(matches(try parse("search: http"), task("Read https://example.com")))
        XCTAssertFalse(matches(.predicate("search", "\u{301}"), task("Any title")), "A word folded to empty must not match everything")
        XCTAssertFalse(matches(.predicate("search", "email \u{301}"), task("Send email")), "Every requested word must stay meaningful after folding")
    }
    func testSearchQuotedOperatorWordsAndPunctuationKeepTheirLiteralMeaning() throws {
        for value in ["AND OR NOT", "& | ! ( )", #"quote \" and \\ path"#, "meeting,today", "send\nemail"] {
            let rule = FilterRule.predicate("search", value)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertTrue(matches(rule, task(value)), value)
        }
        for value in ["\u{301}", "email \u{301}"] {
            let rule = FilterRule.predicate("search", value)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule, "Quotes must survive adjacent combining scalars")
            XCTAssertFalse(matches(rule, task("Send email")), "Literal combining terms must not disappear from a query")
        }
        XCTAssertEqual(try parse("search: email \u{301}"), .predicate("search", "email \u{301}"), "Whitespace must not consume adjacent accents")
        XCTAssertEqual(try parse(#"search: "AND" & no labels"#), .and([.predicate("search", "AND"), .predicate("no_labels", "")]))
        XCTAssertEqual(try parse(#"search:"OR" OR recurring"#), .or([.predicate("search", "OR"), .predicate("recurring", "")]))
        XCTAssertEqual(try parse("search: send email & p1 | recurring"), .or([.and([.predicate("search", "send email"), .predicate("priority", "1")]), .predicate("recurring", "")]))
    }
    func testSearchRejectsEmptyOverlongAndMalformedQueriesWithoutMergingSections() throws {
        for expression in ["search:", #"search:"""#, "search: & today", "search: AND", "search:" + String(repeating: "x", count: 401), #"search:"unterminated"#] {
            XCTAssertThrowsError(try parse(expression), expression)
        }
        XCTAssertNoThrow(try parse("search:" + String(repeating: "x", count: 400)))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("search", " \n\t").json))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("search", String(repeating: "e\u{301}", count: 201)).json))
        XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("search"), "value": .number(1)])))
        XCTAssertEqual(try parse("today, overdue"), .sections([.predicate("today", ""), .predicate("overdue", "")]))
    }
    func testTimeLabelsAndRecurrenceAreIndependentMetadataConditions() throws {
        let plain = task("plain"), allDay = task("day", ["due_date": .string("2026-10-05")]), timed = task("timed", ["due_date": .string("2026-10-05"), "due_time": .string("00:00:00")]), labelled = task("labelled", ["labels": .array([.string("waiting-id")])]), repeating = task("repeat", ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")])])
        XCTAssertTrue(matches(try parse("no time"), plain)); XCTAssertTrue(matches(try parse("no time"), allDay)); XCTAssertFalse(matches(try parse("no time"), timed))
        XCTAssertTrue(matches(try parse("no labels"), plain)); XCTAssertFalse(matches(try parse("no labels"), labelled))
        XCTAssertFalse(matches(try parse("recurring"), plain)); XCTAssertTrue(matches(try parse("recurring"), repeating))
        XCTAssertTrue(matches(try parse("!recurring & !no time"), timed))
        XCTAssertFalse(matches(try parse("!recurring"), repeating))
        for field in ["recurring", "no_time", "no_labels"] {
            for value in [JSON.string("unexpected"), .number(1), .bool(false), .null, .object([:]), .array([])] {
                XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string(field), "value": value])))
            }
        }
        XCTAssertEqual(try parse("no priority"), .predicate("priority", "4"))
    }
    func testProjectAndLabelShorthandsKeepStableTargetsIncludingQuotedNames() throws {
        XCTAssertEqual(try parse("#Work & %waiting"), try parse("project:Work AND label:waiting"))
        XCTAssertEqual(try parse("#Work & @waiting"), try parse("project:Work AND label:waiting"))
        XCTAssertEqual(try parse("#Inbox"), .predicate("inbox", ""))
        let weird = Record(["id": .string("weird"), "name": .string("A & B, OR")])
        let c = FilterContext(projects: [weird], labels: [weird])
        XCTAssertEqual(try parse(#"#"A & B, OR" | %"A & B, OR""#, context: c), .or([.predicate("project", "weird"), .predicate("label", "weird")]))
        let leading = Record(["id": .string("leading-mark"), "name": .string("\u{301}Name")])
        let leadingContext = FilterContext(projects: [leading], labels: [leading])
        for (prefix, field) in [("#", "project"), ("%", "label"), ("@", "label")] {
            let query = prefix + "\"" + leading.name + "\""
            let rule = try parse(query, context: leadingContext)
            XCTAssertEqual(rule, .predicate(field, leading.id))
            XCTAssertEqual(try parse(rule.expression(in: leadingContext), context: leadingContext), rule)
        }
        let rule = try parse("#Work & !%waiting")
        let renamed = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Renamed")])], labels: context.labels)
        XCTAssertNoThrow(try rule.validate(in: renamed)); XCTAssertEqual(try parse(rule.expression(in: renamed), context: renamed), rule)
        XCTAssertThrowsError(try rule.validate(in: FilterContext(projects: renamed.projects)))
        for expression in ["#missing", "%missing", "#", "%", "@"] { XCTAssertThrowsError(try parse(expression), expression) }
    }
    func testNewConditionsRoundTripWithoutInventingCaptureSettings() throws {
        let rule = try parse(#"search:"send email" & no time & no labels & recurring & #Work"#)
        XCTAssertEqual(try FilterRule(document: rule.document), rule)
        XCTAssertEqual(try parse(rule.expression(in: context)), rule)
        XCTAssertEqual(rule.captureDefaults(in: context, today: "2026-10-05"), ["project_id": .string("work-id")])
        XCTAssertTrue(try parse("no time OR recurring").captureDefaults(in: context, today: "2026-10-05").isEmpty)
        XCTAssertThrowsError(try FilterRule(document: .object(["version": .number(1), "root": FilterRule.predicate("future_field", "").json])))
    }
    func testNewFilterPredicatesInvalidateTaskCacheWhenInputsChange() throws {
        let cache = TaskCache(); var row = task("Send email", ["description": .string("Café agenda")])
        cache.update([row]); var query = TaskQuery(scope: .saved("example")); query.filter = try parse("search: cafe email & no time & no labels & !recurring")
        XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        for (field, value) in [("description", JSON.string("Agenda")), ("due_time", .string("09:00")), ("labels", .array([.string("waiting")])), ("is_recurring", .bool(true))] {
            var changed = row; changed[field] = value; cache.update([changed]); XCTAssertTrue(cache.matching(query).isEmpty, field)
            cache.update([row]); XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        }
        row["description"] = .string("Café email"); row["title"] = .string("Other"); cache.update([row]); XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
    }
    func testNewQueryFieldsSurviveOfflineWireAndAccountCacheEncoding() throws {
        let rule = try parse("search: email & no time & no labels & recurring")
        let row = Record(["id": .string("filter-id"), "user_id": .string("owner"), "name": .string("Email review"), "query_ast": rule.document])
        let mutation = Mutation(table: "saved_views", recordID: row.id, method: "POST", fields: row.fields)
        let original = Snapshot(tables: ["saved_views": [row]], pending: [mutation])
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original); XCTAssertEqual(restored.pending[0].fields["query_ast"], rule.document)
        XCTAssertEqual(try FilterRule(document: restored.tables["saved_views"]![0]["query_ast"]), rule)
    }
    func testClockFiltersCanonicalizeAndExcludeTheBoundaryMinute() throws {
        let rows = [task("before", ["due_date": .string("2026-10-05"), "due_time": .string("13:59:00")]), task("on", ["due_date": .string("2026-10-05"), "due_time": .string("14:00")]), task("after", ["due_date": .string("2026-10-06"), "due_time": .string("14:01")]), task("all-day", ["due_date": .string("2026-10-05")]), task("deadline", ["deadline_date": .string("2026-10-05")])]
        for (expression, expected) in [("time before: 2 PM", ["before"]), ("time:14:00", ["on"]), ("time after:2pm", ["after"]), ("today & time before:14:00", ["before"])] {
            let rule = try parse(expression)
            XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertTrue(rule.captureDefaults(in: context, today: "2026-10-05").isEmpty || expression.hasPrefix("today"))
        }
        for (raw, expected) in [("12am", "00:00"), ("12 PM", "12:00"), ("1:05 AM", "01:05"), ("23:59", "23:59"), ("0:00", "00:00")] { XCTAssertEqual(try FilterTimeReference.canonical(raw), expected) }
    }
    func testDatedTimeFiltersCompareInstantsAndExcludeDateOnlyDeadlineFallback() throws {
        let rows = [task("past", ["due_date": .string("2026-10-04"), "due_time": .string("23:59")]), task("before", ["due_date": .string("2026-10-05"), "due_time": .string("13:59")]), task("on", ["due_date": .string("2026-10-05"), "due_time": .string("14:00")]), task("after", ["due_date": .string("2026-10-05"), "due_time": .string("14:01")]), task("future", ["due_date": .string("2026-10-06"), "due_time": .string("01:00")]), task("all-day", ["due_date": .string("2026-10-04")]), task("deadline", ["deadline_date": .string("2026-10-04")])]
        for (expression, expected) in [("date before:today at 2pm", ["past", "before"]), ("date:today at 14:00", ["on"]), ("date after:today at 2pm", ["after", "future"]), ("effective-due before:today at 2pm", ["past", "before"]), ("date:today & time before:2pm", ["before"])] {
            let rule = try parse(expression)
            XCTAssertEqual(rows.filter { matches(rule, $0) }.map(\.id), expected, expression)
            XCTAssertEqual(try parse(rule.expression(in: context)), rule)
            XCTAssertTrue(rule.captureDefaults(in: context, today: "2026-10-05").isEmpty || expression.contains("date:today &"))
        }
        XCTAssertEqual(try parse("date before: Tomorrow AT 2 PM"), .predicate("planned_before", "tomorrow at 14:00"))
    }
    func testTimedFiltersFollowViewerZoneAndPreserveTheChosenRepeatedInstant() throws {
        let fixed = task("fixed", ["due_date": .string("2026-10-05"), "due_time": .string("00:30:00"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-04T22:30:00Z")])
        XCTAssertTrue(matches(try parse("time:00:30"), fixed))
        XCTAssertTrue(matches(try parse("time:6:30pm"), fixed, zone: "America/New_York"))
        XCTAssertTrue(matches(try parse("date: yesterday at 6:30pm"), fixed, zone: "America/New_York"))
        XCTAssertFalse(matches(try parse("date: today at 6:30pm"), fixed, zone: "America/New_York"))
        var first = task("fold", ["due_date": .string("2026-10-25"), "due_time": .string("02:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-25T00:30:00Z")])
        let on = try parse("date:2026-10-25 at 02:30"), after = try parse("date after:2026-10-25 at 02:30")
        XCTAssertTrue(matches(on, first)); XCTAssertFalse(matches(after, first))
        first["scheduled_at"] = .string("2026-10-25T01:30:00Z")
        XCTAssertFalse(matches(on, first)); XCTAssertTrue(matches(after, first)); XCTAssertTrue(matches(try parse("time:02:30"), first))
    }
    func testDatedTimeBoundariesUseNativeGapResolutionAndRelativeDays() throws {
        for (day, zone, requested, resolved) in [("2026-03-29", "Europe/Copenhagen", "02:15", "03:00"), ("2026-10-04", "Australia/Lord_Howe", "02:15", "02:30")] {
            let row = task("gap", ["due_date": .string(day), "due_time": .string(resolved), "time_zone": .string(zone)])
            let rule = try parse("date: today at " + requested)
            XCTAssertTrue(rule.matches(row, today: day, userID: "owner", labels: [], timeZone: zone))
            XCTAssertFalse(rule.matches(row, today: "2026-10-05", userID: "owner", labels: [], timeZone: zone))
        }
        XCTAssertNil(FilterTimeReference.boundary("2011-12-30 at 12:00", today: "2011-12-29", timeZone: "Pacific/Apia"))
    }
    func testTimeGrammarRejectsMalformedRulesAndNeverNormalizesInvalidTasks() throws {
        for expression in ["time:", "time:25:00", "time:13pm", "time:12:60", "time:14:0", "time:+2 hours", "time:now", "time:1 4:00", "time:14:00Z", "date:today at 2pm at 3pm", "date:tomorrow at now", "deadline on:today at 2pm", "deadline before:today at 14:00"] { XCTAssertThrowsError(try parse(expression), expression) }
        for value: JSON in [.null, .number(14), .bool(true), .array([])] { XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("planned_time_before"), "value": value]))) }
        let rule = try parse("time before:23:59")
        for fields: [String: JSON] in [["due_time": .string("14:00")], ["due_date": .string("2026-02-30"), "due_time": .string("14:00")], ["due_date": .string("2026-10-05"), "due_time": .string("25:00")], ["due_date": .string("2026-10-05"), "due_time": .string("14:00:99")], ["due_date": .string("2026-10-05"), "due_time": .string("14:00"), "time_zone": .string("Missing/Zone")]] { XCTAssertFalse(matches(rule, task("bad", fields))) }
    }
    func testTimedFilterCacheAndOfflineSnapshotKeepCanonicalQueriesAndTaskClocks() throws {
        let rule = try parse("date before:tomorrow at 2pm & time after:9am")
        var row = task("timed", ["due_date": .string("2026-10-06"), "due_time": .string("13:00"), "time_zone": .string("Europe/Copenhagen")])
        let cache = TaskCache(); cache.update([row])
        var query = TaskQuery(scope: .saved("timed"), today: "2026-10-05"); query.filter = rule; query.timeZone = "Europe/Copenhagen"
        XCTAssertEqual(cache.matching(query).map(\.id), [row.id])
        query.today = "2026-10-04"; XCTAssertTrue(cache.matching(query).isEmpty)
        query.today = "2026-10-05"; query.timeZone = "America/New_York"; XCTAssertTrue(cache.matching(query).isEmpty)
        row["due_time"] = .string("14:00"); cache.update([row]); query.timeZone = "Europe/Copenhagen"; XCTAssertTrue(cache.matching(query).isEmpty)
        let view = Record(["id": .string("timed"), "name": .string("Morning"), "query_ast": rule.document])
        let original = Snapshot(tables: ["tasks": [row], "saved_views": [view]], pending: [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)])
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(original)), original)
    }

}

final class OrganizationTransportTests: XCTestCase {
    @MainActor func testNewQueryPredicatesSurviveAuthenticatedRESTBodyAndRepresentation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"fixture","refresh_token":"refresh","expires_in":3600,"user":{"id":"owner"}}"#.utf8))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var parser = try FilterParser(#"search:"café email" & recurring & no time & no labels"#, context: FilterContext())
        let rule = try parser.parse()
        let row = Record(["id": .string("filter-id"), "user_id": .string("owner"), "name": .string("Email review"), "query_ast": rule.document])
        var requests = 0
        AuthTransportTests.Stub.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/saved_views")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            if request.httpMethod == "POST" {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "id")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=representation")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                }
                let sent = try JSONDecoder().decode(Record.self, from: data)
                XCTAssertEqual(sent, row); XCTAssertEqual(try FilterRule(document: sent["query_ast"]), rule)
            } else { XCTAssertEqual(request.httpMethod, "GET") }
            return (200, try JSONEncoder().encode([row]))
        }
        defer { AuthTransportTests.Stub.handler = nil }
        let response = try await backend.send(Mutation(table: "saved_views", recordID: row.id, method: "POST", fields: row.fields), expectedAccount: "owner")
        let saved = try XCTUnwrap(response)
        XCTAssertEqual(saved, row)
        let rows = try await backend.rows("saved_views")
        XCTAssertEqual(rows, [row]); XCTAssertEqual(try FilterRule(document: rows[0]["query_ast"]), rule); XCTAssertEqual(requests, 2)
    }

    @MainActor func testCompositeUpsertsAndEscapedStableKeysUseAuthenticatedRequests() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"fixture","refresh_token":"refresh","expires_in":3600,"user":{"id":"owner"}}"#.utf8))
        let backend = Backend(configuration: ["URL":"https://native-auth.test", "Key":"public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        for table in ["favorites", "view_preferences", "view_orders"] {
            let key = "scope:view:filter/group:all & done"
            AuthTransportTests.Stub.handler = { request in
                XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/rest/v1/" + table)
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "user_id,id")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=representation")
                return (200, try JSONEncoder().encode([Record(["id": .string(key), "user_id": .string("owner")])]))
            }
            try await backend.send(Mutation(table: table, recordID: key, method: "POST", fields: ["id": .string(key), "user_id": .string("owner")]))
            AuthTransportTests.Stub.handler = { request in
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "eq." + key)
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
                return (200, Data("[]".utf8))
            }
            try await backend.send(Mutation(table: table, recordID: key, method: "DELETE", fields: [:]))
        }
        AuthTransportTests.Stub.handler = { _ in (200, Data("[]".utf8)) }
        do { try await backend.send(Mutation(table: "favorites", recordID: "missing", method: "PATCH", fields: ["order_index": .number(1)])); XCTFail("Empty representation must retain the offline mutation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer available")) }
    }

}


extension FilterTests {
    func testElapsedWindowGrammarRoundTripBoundsAndDateOnlyRejection() throws {
        for (source, expected) in [("now", "now"), ("+4 hours", "+4 hours"), ("in one minute", "+1 minute"), ("in 120 minutes", "+2 hours"), ("-30 minutes", "-30 minutes"), ("+168 hours", "+168 hours")] {
            for prefix in ["date before", "date after", "effective-due before", "effective-due after"] {
                let rule = try parse(prefix + ":" + source)
                XCTAssertEqual(try parse(rule.expression(in: context)), rule)
                XCTAssertEqual(try FilterRule(document: rule.document), rule)
                XCTAssertTrue(rule.usesClockWindow); XCTAssertTrue(rule.expression(in: context).contains(expected))
                XCTAssertEqual(rule.captureDefaults(in: context, today: "2026-10-08"), [:])
            }
        }
        for bad in ["date:now", "deadline before:+4 hours", "created before:now", "time before:now", "date before:+169 hours", "date before:+10081 minutes", "date before:+0 hours", "date before:+-2 hours", "date after:-one thousand minutes", "date before:+4 hours at 2pm", "date before:+999999999999999999999 hours"] { XCTAssertThrowsError(try parse(bad), bad) }
        XCTAssertEqual(try parse("before:2026-10-08"), .predicate("before", "2026-10-08"))
    }
    func testElapsedWindowStrictMinutesAndTimedPlanRequirement() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-08T10:00:59Z")!
        func row(_ id: String, _ day: String, _ clock: String) -> Record { task(id, ["due_date": .string(day), "due_time": .string(clock)]) }
        let rows = [row("past", "2026-10-07", "23:59"), row("inside", "2026-10-08", "13:59"), row("edge", "2026-10-08", "14:00"), row("after", "2026-10-08", "14:01"), row("all-day", "2026-10-08", ""), row("bad-clock", "2026-10-08", "25:00"), task("deadline-only", ["deadline_date": .string("2026-10-07")])]
        let cache = TaskCache(); cache.update(rows)
        func ids(_ expression: String) throws -> Set<String> { Set(cache.matching(TaskQuery(scope: .all, today: "2026-10-08", filter: try parse(expression), now: now, timeZone: "UTC")).map(\.id)) }
        XCTAssertEqual(try ids("date before:+4 hours"), ["past", "inside"])
        XCTAssertEqual(try ids("date after:+4 hours"), ["after"])
        XCTAssertEqual(try ids("effective-due before:+4 hours"), ["past", "inside"])
        XCTAssertEqual(try ids("date after:now & date before:+4 hours"), ["inside"])
        XCTAssertEqual(try ids("date before:-30 minutes"), ["past"])
    }
    func testElapsedWindowMissingReaderClockFailsClosedThroughNegationAndBooleanGroups() throws {
        let row = task("safe", [:])
        for input in ["date before:now", "NOT date before:now", "all OR date after:+1 hour", "NOT (date after:now AND p1)"] {
            let rule = try parse(input)
            XCTAssertFalse(rule.matches(row, today: "2026-10-08", userID: "a", labels: [], timeZone: "UTC"))
            XCTAssertFalse(rule.matches(row, today: "2026-10-08", userID: "a", labels: [], timeZone: "UTC", now: Date(timeIntervalSinceReferenceDate: .nan)))
            XCTAssertFalse(rule.resultMatches(row, context: context, today: "2026-10-08", timeZone: "UTC"))
        }
        let sections = try parse("NOT date before:now, all")
        XCTAssertTrue(sections.matches(row, today: "2026-10-08", userID: "a", labels: [], timeZone: "UTC"))
        XCTAssertEqual(TaskGrouping.queryGroups([row], rule: sections, by: "none", context: context, today: "2026-10-08", timeZone: "UTC").map { $0.tasks.map(\.id) }, [[], ["safe"]])
    }
    func testElapsedWindowCacheTicksWithoutTaskWritesAndOrdinaryQueriesKeepCache() throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!
        let rows = [task("edge", ["due_date": .string("2026-10-08"), "due_time": .string("10:01")])]
        let cache = TaskCache(); cache.update(rows)
        let window = TaskQuery(scope: .all, filter: try parse("date before:+1 minute"), timeZone: "UTC")
        func context(_ seconds: Double) -> TaskCalendarContext { TaskCalendarContext(now: start.addingTimeInterval(seconds), timeZone: TimeZone(secondsFromGMT: 0)!) }
        XCTAssertEqual(cache.matching(context(0).applying(to: window)).map(\.id), [])
        let initial = cache.computationCount
        XCTAssertEqual(cache.matching(context(59).applying(to: window)).map(\.id), []); XCTAssertEqual(cache.computationCount, initial)
        XCTAssertEqual(cache.matching(context(60).applying(to: window)).map(\.id), ["edge"]); XCTAssertEqual(cache.computationCount, initial + 1)
        let ordinary = TaskQuery(scope: .all, filter: try parse("date:today"))
        _ = cache.matching(context(0).applying(to: ordinary)); let ordinaryCount = cache.computationCount
        _ = cache.matching(context(60).applying(to: ordinary)); XCTAssertEqual(cache.computationCount, ordinaryCount)
        XCTAssertEqual(cache.tasks, rows); XCTAssertFalse(cache.update(rows))
        XCTAssertEqual(TaskCalendarContext.refreshDelay(after: start.addingTimeInterval(59), timeZone: TimeZone(secondsFromGMT: 0)!), 1, accuracy: 0.001)
    }
    func testElapsedWindowsUseAbsoluteElapsedTimeThroughDSTTravelAndMidnight() throws {
        for (instant, expected) in [("2026-03-29T00:30:00Z", "2026-03-29T04:30:00Z"), ("2026-10-25T00:30:00Z", "2026-10-25T04:30:00Z"), ("2026-10-03T15:15:00Z", "2026-10-03T19:15:00Z"), ("2026-10-08T23:30:00Z", "2026-10-09T03:30:00Z")] {
            let now = ISO8601DateFormatter().date(from: instant)!
            XCTAssertEqual(FilterClockWindow.boundary("+4 hours", now: now), ISO8601DateFormatter().date(from: expected))
            var fixed = task("fixed", ["due_date": .string("2026-10-09"), "due_time": .string("00:00"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-08T22:00:00Z")])
            let rule = try parse("date before:+4 hours")
            XCTAssertEqual(rule.matches(fixed, today: "2026-10-08", userID: "a", labels: [], timeZone: "Europe/Copenhagen", now: now), rule.matches(fixed, today: "2026-10-08", userID: "a", labels: [], timeZone: "Pacific/Honolulu", now: now))
            fixed["time_zone"] = .null; fixed["scheduled_at"] = .null
            if instant.hasSuffix("23:30:00Z") {
                XCTAssertTrue(rule.matches(fixed, today: "2026-10-08", userID: "a", labels: [], timeZone: "UTC", now: now))
                XCTAssertFalse(rule.matches(fixed, today: "2026-10-08", userID: "a", labels: [], timeZone: "Pacific/Honolulu", now: now))
            }
        }
    }
    func testElapsedQueriesKeepRelativeDocumentThroughOfflineQueueAndSectionGrouping() throws {
        let rule = try parse("date before:+4 hours, date after:now & date before:+4 hours")
        let view = Record(["id": .string("clock-view"), "name": .string("Next hours"), "query_ast": rule.document])
        var snapshot = Snapshot(); snapshot.tables["saved_views"] = [view]
        snapshot.pending = [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)]
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = try FilterRule(document: decoded.tables["saved_views"]![0]["query_ast"])
        XCTAssertEqual(restored, rule); XCTAssertEqual(decoded.pending[0].fields["query_ast"], rule.document)
        let now = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!
        let rows = [task("past", ["due_date": .string("2026-10-07"), "due_time": .string("09:00")]), task("next", ["due_date": .string("2026-10-08"), "due_time": .string("13:00")])]
        let groups = TaskGrouping.queryGroups(rows, rule: restored, by: "none", context: context, today: "2026-10-08", timeZone: "UTC", now: now)
        XCTAssertEqual(groups.map { Set($0.tasks.map(\.id)) }, [["past", "next"], ["next"]]); XCTAssertEqual(groups.map(\.id).count, 2)
        XCTAssertEqual(restored.captureDefaults(in: context, today: "2026-10-08"), [:])
    }
}


extension FilterTests {
    func testDatePreferenceFilterCacheGroupingDefaultsAndTimedBoundaries() throws {
        let c = DatePhrasePreferences(nextWeek:6,weekend:1), day = "2026-10-08"
        var local = context; local.datePreferences = c
        let rule = try parse("date:next week, deadline:this weekend",context:local)
        XCTAssertEqual(try FilterRule(document:rule.document),rule); XCTAssertEqual(try parse(rule.expression(in:local),context:local),rule)
        let rows = [task("friday",["due_date":.string("2026-10-09"),"due_time":.string("13:59")]),task("monday",["due_date":.string("2026-10-12")]),task("sunday",["deadline_date":.string("2026-10-11")])]
        let cache=TaskCache(); cache.update(rows)
        var query=TaskQuery(scope:.all,today:day,filter:rule,datePreferences:c,timeZone:"UTC")
        XCTAssertEqual(Set(cache.matching(query).map(\.id)),["friday","sunday"])
        let groups=TaskGrouping.queryGroups(rows,rule:rule,by:"none",context:local,today:day,timeZone:"UTC")
        XCTAssertEqual(groups.map { $0.tasks.map(\.id) },[["friday"],["sunday"]])
        query.datePreferences=DatePhrasePreferences(); XCTAssertEqual(Set(cache.matching(query).map(\.id)),["monday"])
        XCTAssertEqual(cache.tasks,rows)
        XCTAssertEqual(try parse("date:next week",context:local).captureDefaults(in:local,today:day,timeZone:"UTC")["due_date"],.string("2026-10-09"))
        let timed=try parse("date before:next week at 14:00",context:local)
        XCTAssertTrue(timed.matches(rows[0],today:day,userID:"owner",labels:[],timeZone:"UTC",datePreferences:c))
    }
    func testDatePreferenceUnsupportedContextFailsClosedThroughNegationAndSafeIndependentQueries() throws {
        let row=task("safe",[:]); var missing=context; missing.datePreferences=nil
        for input in ["date:next week","NOT deadline:this weekend","all OR created before:next weekend","NOT (date before:next week at 14:00 AND p1)"] {
            let rule=try parse(input); XCTAssertThrowsError(try rule.validate(in:missing)); XCTAssertFalse(rule.matches(row,today:"2026-10-08",userID:"owner",labels:[],timeZone:"UTC",datePreferences:nil))
        }
        let rule=try parse("NOT date:next week, all")
        XCTAssertTrue(rule.matches(row,today:"2026-10-08",userID:"owner",labels:[],timeZone:"UTC",datePreferences:nil))
        XCTAssertEqual(TaskGrouping.queryGroups([row],rule:rule,by:"none",context:missing,today:"2026-10-08",timeZone:"UTC").map { $0.tasks.map(\.id) },[[],["safe"]])
    }
}
