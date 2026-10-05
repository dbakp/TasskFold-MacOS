import XCTest
@testable import TaskfoldCore

final class FilterTests: XCTestCase {
    let context = FilterContext(projects: [Record(["id": .string("work-id"), "name": .string("Work")])], sections: [Record(["id": .string("section-id"), "name": .string("Next steps")])], labels: [Record(["id": .string("waiting-id"), "name": .string("waiting")])], userID: "owner")
    func parse(_ input: String, context: FilterContext? = nil) throws -> FilterRule { var parser = try FilterParser(input, context: context ?? self.context); return try parser.parse() }
    func task(_ id: String, _ fields: [String: JSON] = [:]) -> Record { var row = Record(["id": .string(id), "title": .string(id), "completed": .bool(false), "priority": .number(4)]); for (key, value) in fields { row[key] = value }; return row }
    func matches(_ rule: FilterRule, _ row: Record, labels: [FilterReference] = [FilterReference(id: "waiting-id", name: "waiting")], zone: String = "Europe/Copenhagen") -> Bool { rule.matches(row, today: "2026-10-05", userID: "owner", labels: labels, timeZone: zone) }
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
}

final class OrganizationTransportTests: XCTestCase {
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
