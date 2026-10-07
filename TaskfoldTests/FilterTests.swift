import XCTest
@testable import TaskfoldCore

final class FilterTests: XCTestCase {
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
        for expression in ["date:", "date:2026-02-30", "date:2026-10-05T12:00:00Z", "date:31 February", "date:next week", "date:+4 hours", "date:3 days", "date:-3 days", "date:in 3651 days", "date:today at 25:00", "date:today p1", "date:today, date:tomorrow", "effective-due before:"] { XCTAssertThrowsError(try parse(expression), expression) }
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
        for expression in ["search:", #"search:"""#, "search: & today", "search: AND", "search:" + String(repeating: "x", count: 401), "search: Meeting, today", #"search:"unterminated"#] {
            XCTAssertThrowsError(try parse(expression), expression)
        }
        XCTAssertNoThrow(try parse("search:" + String(repeating: "x", count: 400)))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("search", " \n\t").json))
        XCTAssertThrowsError(try FilterRule(json: FilterRule.predicate("search", String(repeating: "e\u{301}", count: 201)).json))
        XCTAssertThrowsError(try FilterRule(json: .object(["op": .string("predicate"), "field": .string("search"), "value": .number(1)])))
        XCTAssertThrowsError(try parse("today, overdue")) { XCTAssertTrue($0.localizedDescription.contains("separate filters")) }
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
        for expression in ["#missing", "%missing", "#", "%", "@", "#Work*", "%wait*"] { XCTAssertThrowsError(try parse(expression), expression) }
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
